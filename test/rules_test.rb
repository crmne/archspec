# frozen_string_literal: true

require 'test_helper'

class RulesTest < ArchSpecTest
  def test_forbidden_dependencies_are_reported
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          UsersController
        end
      RUBY

      write "#{root}/app/controllers/users_controller.rb", <<~RUBY
        class UsersController
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'dependencies.forbid', diagnostics.first.rule
      assert_match(/models must not depend on controllers/, diagnostics.first.message)
    end
  end

  def test_allow_dependencies_reports_other_declared_components
    with_project do |root|
      write "#{root}/app/controllers/users_controller.rb", <<~RUBY
        class UsersController
          AuditLog
        end
      RUBY

      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/app/jobs/audit_log.rb", "class AuditLog; end\n"

      definition = ArchSpec.define do
        component :controllers, in: 'app/controllers/**/*.rb'
        component :models, in: 'app/models/**/*.rb'
        component :jobs, in: 'app/jobs/**/*.rb'
        controllers.can_only_use :models
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/controllers may not depend on jobs/, diagnostics.first.message)
    end
  end

  def test_protocol_and_method_call_rules
    with_project do |root|
      write "#{root}/app/services/good_service.rb", <<~RUBY
        class GoodService
          def call
            User
          end
        end
      RUBY

      write "#{root}/app/services/bad_service.rb", <<~RUBY
        class BadService
          def run
            render :show
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.must_implement :call
        services.cannot_call :render
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['methods.forbid', 'protocol.must_implement'], diagnostics.map(&:rule).sort
      assert(diagnostics.any? { |diagnostic| diagnostic.message == 'BadService must implement #call' })
      assert(diagnostics.any? { |diagnostic| diagnostic.message == 'services must not call #render' })
    end
  end

  def test_cycle_rule_reports_component_cycles
    with_project do |root|
      write "#{root}/app/a/alpha.rb", "class Alpha; Beta; end\n"
      write "#{root}/app/b/beta.rb", "class Beta; Alpha; end\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :a, in: 'app/a/**/*.rb'
        component :b, in: 'app/b/**/*.rb'
        no_cycles
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'dependencies.no_cycles', diagnostics.first.rule
      assert_match(/a -> b -> a|b -> a -> b/, diagnostics.first.message)
    end
  end

  def test_disable_next_line_suppresses_one_rule
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          # archspec:disable-next-line dependencies.forbid -- migrating old controller coupling
          UsersController
          OtherController
        end
      RUBY

      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      write "#{root}/app/controllers/other_controller.rb", "class OtherController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/OtherController/, diagnostics.first.evidence)
    end
  end

  def test_block_suppression_suppresses_until_enable
    with_project do |root|
      write "#{root}/app/services/create_user.rb", <<~RUBY
        class CreateUser
          # archspec:disable methods.forbid -- temporary controller API cleanup
          def call
            render :new
          end
          # archspec:enable methods.forbid

          def rollback
            redirect_to "/"
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_call :render, :redirect_to
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/redirect_to/, diagnostics.first.message)
    end
  end

  def test_trailing_disable_comment_suppresses_its_own_line
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          UsersController # archspec:disable dependencies.forbid -- accepted boundary
          # archspec:enable dependencies.forbid
          OtherController
        end
      RUBY

      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      write "#{root}/app/controllers/other_controller.rb", "class OtherController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/OtherController/, diagnostics.first.evidence)
    end
  end

  def test_parse_errors_are_reported
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def call
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.rule == 'parser.syntax' })
    end
  end

  def test_cannot_call_with_receiver_none_ignores_receivered_calls
    with_project do |root|
      write "#{root}/app/services/export.rb", <<~RUBY
        class Export
          def run
            pdf.render
            self.render
            render :show
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_call :render, receiver: :none
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 2, diagnostics.size
      assert(diagnostics.all? { |diagnostic| diagnostic.message == 'services must not call #render' })
    end
  end

  def test_cannot_call_treats_current_attributes_attribute_as_own_api
    with_project do |root|
      write "#{root}/app/models/current.rb", <<~RUBY
        class Current < ActiveSupport::CurrentAttributes
          attribute :session, :user

          def identity
            session.identity
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :session, receiver: :none
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_cannot_call_matches_any_receiver_by_default
    with_project do |root|
      write "#{root}/app/queries/user_query.rb", <<~RUBY
        class UserQuery
          def run
            user.update(name: "x")
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :queries, in: 'app/queries/**/*.rb'
        queries.cannot_call :update
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
    end
  end

  def test_forbidden_method_definitions_are_reported
    with_project do |root|
      write "#{root}/app/services/create_user.rb", <<~RUBY
        class CreateUser
          def call
            User
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_define :call
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'methods.define_forbid', diagnostics.first.rule
      assert_match(/services must not define #call/, diagnostics.first.message)
      assert_match(/CreateUser defines instance method call/, diagnostics.first.evidence)
    end
  end

  def test_instantiate_and_invoke_is_reported
    with_project do |root|
      write "#{root}/app/services/create_user.rb", <<~RUBY
        class CreateUser
          def run
            UserBuilder.new(params).build
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_instantiate_and_invoke
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'objects.instantiate_and_invoke_forbid', diagnostics.first.rule
      assert_match(/services must not instantiate and immediately invoke UserBuilder#build/, diagnostics.first.message)
    end
  end

  def test_instantiate_and_invoke_ignores_new_called_on_a_variable
    with_project do |root|
      write "#{root}/app/services/create_user.rb", <<~RUBY
        class CreateUser
          def run(factory)
            factory.new.call
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_instantiate_and_invoke
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_delegate_with_false_prefix_is_treated_as_an_own_method
    with_project do |root|
      write "#{root}/app/services/export.rb", <<~RUBY
        class Export
          delegate :render, to: :renderer, prefix: false

          def run
            render
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_call :render, receiver: :none
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_must_implement_counts_inherited_and_mixed_in_methods
    with_project do |root|
      write "#{root}/app/commands/application_command.rb", <<~RUBY
        class ApplicationCommand
          def perform
          end
        end
      RUBY

      write "#{root}/app/commands/callable.rb", <<~RUBY
        module Callable
          def call
          end
        end
      RUBY

      write "#{root}/app/commands/import_users.rb", <<~RUBY
        class ImportUsers < ApplicationCommand
        end
      RUBY

      write "#{root}/app/commands/export_users.rb", <<~RUBY
        class ExportUsers
          include Callable
        end
      RUBY

      write "#{root}/app/commands/broken_command.rb", <<~RUBY
        class BrokenCommand
        end
      RUBY

      definition = ArchSpec.define do
        component :commands, in: 'app/commands/**/*.rb'
        commands.must_implement_one_of :perform, :call
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/BrokenCommand must implement one of/, diagnostics.first.message)
      assert_equal :high, diagnostics.first.confidence
    end
  end

  def test_must_implement_downgrades_confidence_for_unresolved_ancestors
    with_project do |root|
      write "#{root}/app/commands/import_users.rb", <<~RUBY
        class ImportUsers < SomeGem::Base
        end
      RUBY

      definition = ArchSpec.define do
        component :commands, in: 'app/commands/**/*.rb'
        commands.must_implement :perform
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal :medium, diagnostics.first.confidence
      assert_match(/unresolved ancestors: SomeGem::Base/, diagnostics.first.evidence)
    end
  end

  def test_concern_independence_flags_reference_to_includer
    with_project do |root|
      write "#{root}/app/models/concerns/chargeable.rb", <<~RUBY
        module Chargeable
          def charge
            Order.create!
          end
        end
      RUBY

      write "#{root}/app/models/order.rb", <<~RUBY
        class Order
          include Chargeable
        end
      RUBY

      write "#{root}/app/models/concerns/searchable.rb", <<~RUBY
        module Searchable
          def reindex
            SearchIndex.refresh
          end
        end
      RUBY

      write "#{root}/app/models/product.rb", <<~RUBY
        class Product
          include Searchable
        end
      RUBY

      write "#{root}/app/models/search_index.rb", "class SearchIndex; end\n"

      definition = ArchSpec.define do
        component :concerns, in: 'app/models/concerns/**/*.rb'
        concerns.cannot_reference_includers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['concerns.independence'], diagnostics.map(&:rule)
      assert_equal 1, diagnostics.size
      assert_match(/Chargeable must not reference its includer Order/, diagnostics.first.message)
    end
  end

  def test_can_only_be_used_by_flags_unapproved_consumers
    with_project do |root|
      write "#{root}/app/kernel/money.rb", "class Money; end\n"
      write "#{root}/app/billing/invoice.rb", "class Invoice; Money; end\n"
      write "#{root}/app/reporting/report.rb", "class Report; Money; end\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :kernel, in: 'app/kernel/**/*.rb'
        component :billing, in: 'app/billing/**/*.rb'
        component :reporting, in: 'app/reporting/**/*.rb'
        kernel.can_only_be_used_by :billing
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['dependencies.consumers'], diagnostics.map(&:rule)
      assert_equal 1, diagnostics.size
      assert_match(/kernel may only be used by billing, not reporting/, diagnostics.first.message)
    end
  end

  def test_repeated_consumer_allowlists_merge
    with_project do |root|
      write "#{root}/app/kernel/money.rb", "class Money; end\n"
      write "#{root}/app/billing/invoice.rb", "class Invoice; Money; end\n"
      write "#{root}/app/catalog/price.rb", "class Price; Money; end\n"
      write "#{root}/app/reporting/report.rb", "class Report; Money; end\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :kernel, in: 'app/kernel/**/*.rb'
        component :billing, in: 'app/billing/**/*.rb'
        component :catalog, in: 'app/catalog/**/*.rb'
        component :reporting, in: 'app/reporting/**/*.rb'
        kernel.can_only_be_used_by :billing
        kernel.can_only_be_used_by :catalog
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/not reporting/, diagnostics.first.message)
    end
  end

  def test_forbidden_constants_match_absolute_names_and_children
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          ::ActionController::Base
          ActionView
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_reference_constants 'ActionController'
        models.cannot_reference_constants 'ActionView'
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 2, diagnostics.size
      assert_equal ['models must not reference ActionController::Base',
                    'models must not reference ActionView'], diagnostics.map(&:message).sort
    end
  end

  def test_public_api_flags_outside_references_to_private_constants
    with_project do |root|
      write "#{root}/packs/billing/app/public/billing/invoicer.rb", <<~RUBY
        module Billing
          class Invoicer
          end
        end
      RUBY

      write "#{root}/packs/billing/app/models/billing/ledger.rb", <<~RUBY
        module Billing
          class Ledger
            Invoicer
          end
        end
      RUBY

      write "#{root}/app/controllers/orders_controller.rb", <<~RUBY
        class OrdersController
          Billing::Invoicer
          Billing::Ledger
        end
      RUBY

      definition = ArchSpec.define do
        source 'app/**/*.rb', 'packs/*/app/**/*.rb'
        component :billing, in: 'packs/billing/**/*.rb'
        billing.public_api 'packs/billing/app/public/**/*.rb'
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['dependencies.privacy'], diagnostics.map(&:rule)
      assert_equal 1, diagnostics.size
      assert_match(/Billing::Ledger is private to billing/, diagnostics.first.message)
    end
  end

  def test_public_api_accepts_explicit_constants
    with_project do |root|
      write "#{root}/packs/billing/app/models/billing.rb", <<~RUBY
        module Billing
          class Ledger; end
          class Api; end
        end
      RUBY

      write "#{root}/app/models/order.rb", <<~RUBY
        class Order
          Billing::Api
          Billing::Ledger
        end
      RUBY

      definition = ArchSpec.define do
        source 'app/**/*.rb', 'packs/*/app/**/*.rb'
        component :billing, in: 'packs/billing/**/*.rb'
        billing.public_api constants: 'Billing::Api'
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/Billing::Ledger is private to billing/, diagnostics.first.message)
    end
  end

  def test_must_be_empty_reports_every_file_in_the_component
    with_project do |root|
      write "#{root}/app/services/create_user.rb", "class CreateUser; end\n"

      definition = ArchSpec.define do
        component(:services, in: 'app/services/**/*.rb').must_be_empty(because: 'behavior belongs on models')
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['components.empty'], diagnostics.map(&:rule)
      assert_match(/services must stay empty: behavior belongs on models/, diagnostics.first.message)
    end
  end

  def test_must_be_empty_passes_when_no_files_match
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component(:services, in: 'app/services/**/*.rb').must_be_empty
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_must_implement_one_of_requires_a_method_name
    all_error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.must_implement
      end
    end
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.must_implement_one_of
      end
    end

    assert_match(/must_implement requires at least one method/, all_error.message)
    assert_match(/requires at least one method/, error.message)
  end

  def test_dependency_rules_reject_unknown_components
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_use :controlers
      end
    end

    assert_match(/models\.cannot_use references unknown component: controlers/, error.message)
  end

  def test_cycle_rules_reject_unknown_components
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        no_cycles among: %i[models controlers]
      end
    end

    assert_match(/no_cycles references unknown component: controlers/, error.message)
  end

  def test_can_also_use_grants_extra_targets
    with_project do |root|
      write "#{root}/app/models/order.rb", <<~RUBY
        class Order
          def notify = OrderMailer
        end
      RUBY

      write "#{root}/app/models/order_workflow.rb", <<~RUBY
        class OrderWorkflow
          def finish = OrderMailer
        end
      RUBY

      write "#{root}/app/mailers/order_mailer.rb", <<~RUBY
        class OrderMailer
          def deliver = nil
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :workflows, in: 'app/models/**/*_workflow.rb'
        component :mailers, in: 'app/mailers/**/*.rb'
        models.can_only_use :workflows
        workflows.can_also_use :mailers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/models may not depend on mailers/, diagnostics.first.message)
      assert_match(/Order references OrderMailer/, diagnostics.first.evidence)
    end
  end
end
