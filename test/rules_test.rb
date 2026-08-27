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

  def test_rules_carry_a_reason_without_changing_their_fingerprint
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      plain = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end
      explained = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers, because: 'models must remain independent of the request'
      end

      plain_diagnostic = diagnostics_for(plain, root).first
      explained_diagnostic = diagnostics_for(explained, root).first

      assert_equal plain_diagnostic.fingerprint(root: root), explained_diagnostic.fingerprint(root: root)
      assert_equal 'models must remain independent of the request', explained_diagnostic.reason
      assert_equal 'models must remain independent of the request', explained_diagnostic.to_h(root: root)[:reason]
    end
  end

  def test_merged_rules_reject_conflicting_reasons
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers, because: 'one reason'
        models.cannot_use :controllers, because: 'another reason'
      end
    end

    assert_match 'same rule cannot have two reasons', error.message
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

  def test_class_side_protocols_follow_superclasses_and_extended_modules
    with_project do |root|
      write "#{root}/lib/job_support.rb", <<~RUBY
        module Schedulable
          def perform_later = nil
        end

        class ApplicationJob
          def self.enqueue = nil
        end
      RUBY
      write "#{root}/app/jobs/good_job.rb", <<~RUBY
        class GoodJob < ApplicationJob
          extend Schedulable
        end
      RUBY
      write "#{root}/app/jobs/bad_job.rb", "class BadJob; end\n"

      definition = ArchSpec.define do
        source 'lib/**/*.rb'
        component :jobs, in: 'app/jobs/**/*.rb'
        jobs.must_implement :perform_later, scope: :class
        jobs.must_implement_one_of :enqueue, :perform_later, scope: :class
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['BadJob must implement .perform_later',
                    'BadJob must implement one of .enqueue, .perform_later'], diagnostics.map(&:message).sort
    end
  end

  def test_protocols_can_require_a_callable_signature
    with_project do |root|
      write "#{root}/app/services/charge.rb", <<~RUBY
        class Charge
          def call(amount, actor:) = amount
        end
      RUBY
      write "#{root}/app/services/flexible.rb", <<~RUBY
        class Flexible
          def call(amount = nil, **options) = amount
        end
      RUBY
      write "#{root}/app/services/refund.rb", <<~RUBY
        class Refund
          def call = nil
        end
      RUBY
      write "#{root}/app/services/strict.rb", <<~RUBY
        class Strict
          def call(amount, actor:, request_id:) = amount
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.must_implement :call, arity: 1, keywords: :actor
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal [
        'Refund must implement #call accepting 1 positional argument and keywords actor:',
        'Strict must implement #call accepting 1 positional argument and keywords actor:'
      ], diagnostics.map(&:message).sort
      assert diagnostics.all? { |diagnostic| diagnostic.confidence == :high }
      assert_includes diagnostics.map(&:evidence), 'Refund #call accepts 0 positional'
      assert_includes diagnostics.map(&:evidence), 'Strict #call accepts 1 positional, keywords actor:, request_id:'
    end
  end

  def test_protocol_signatures_use_the_method_ruby_will_dispatch_to
    with_project do |root|
      write "#{root}/lib/base_command.rb", <<~RUBY
        class BaseCommand
          def call(amount, actor:) = amount
        end
      RUBY
      write "#{root}/app/commands/charge.rb", <<~RUBY
        class Charge < BaseCommand
          def call(amount) = amount
        end
      RUBY

      definition = ArchSpec.define do
        source 'lib/**/*.rb'
        component :commands, in: 'app/commands/**/*.rb'
        commands.must_implement :call, arity: 1, keywords: :actor
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['Charge must implement #call accepting 1 positional argument and keywords actor:'],
        diagnostics.map(&:message)
      assert_equal 'Charge #call accepts 1 positional', diagnostics.first.evidence
    end
  end

  def test_protocol_options_are_validated
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :jobs, in: 'app/jobs/**/*.rb'
        jobs.must_implement :perform, scope: :singleton
      end
    end
    assert_match 'scope: must be :instance or :class', error.message

    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :jobs, in: 'app/jobs/**/*.rb'
        jobs.must_implement :perform, arity: -1
      end
    end
    assert_match 'arity: must be a non-negative Integer', error.message
  end

  def test_cannot_call_can_match_a_semantic_class_receiver
    with_project do |root|
      write "#{root}/app/models/application_record.rb", <<~RUBY
        class ApplicationRecord < ActiveRecord::Base
        end
      RUBY
      write "#{root}/app/models/user.rb", "class User < ApplicationRecord; end\n"
      write "#{root}/app/models/connection.rb", "class Connection; def self.find_by_sql(query) = query; end\n"
      write "#{root}/app/models/report.rb", <<~RUBY
        class Report
          def users = User.find_by_sql('SELECT * FROM users')
          def raw = Connection.find_by_sql('SELECT 1')
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :find_by_sql, receiver: 'ActiveRecord::Base'
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'models must not call #find_by_sql', diagnostics.first.message
      assert_equal 'Report calls find_by_sql on User', diagnostics.first.evidence
    end
  end

  def test_cannot_call_follows_method_aliases_on_resolved_receivers
    with_project do |root|
      write "#{root}/app/models/store.rb", <<~RUBY
        class Store
          def self.destroy_all = nil

          class << self
            alias_method :wipe, :destroy_all
            alias_method :erase, :wipe
          end
        end
      RUBY
      write "#{root}/app/models/cleanup.rb", <<~RUBY
        class Cleanup
          def call = Store.erase
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :destroy_all
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'models must not call #destroy_all', diagnostics.first.message
      assert_equal 'Cleanup calls erase (alias of destroy_all)', diagnostics.first.evidence
    end
  end

  def test_cannot_call_rejects_non_constant_semantic_receivers
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :save, receiver: :self
      end
    end

    assert_match 'must be :any, :none or a constant name', error.message
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

  def test_cycle_rule_reports_a_tangle_once_with_an_example_cycle
    with_project do |root|
      names = %w[a b c d]
      names.each do |name|
        others = (names - [name]).map { |other| "#{other.upcase}Thing" }.join('; ')
        write "#{root}/app/#{name}/#{name}_thing.rb", "class #{name.upcase}Thing; #{others}; end\n"
      end

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        names.each { |name| component name.to_sym, in: "app/#{name}/**/*.rb" }
        no_cycles
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'component dependency cycle among 4 components: a, b, c, d', diagnostics.first.message
      assert_equal 'a -> b -> a', diagnostics.first.evidence
    end
  end

  def test_cycle_rule_reports_independent_cycles_separately
    with_project do |root|
      write "#{root}/app/a/alpha.rb", "class Alpha; Beta; end\n"
      write "#{root}/app/b/beta.rb", "class Beta; Alpha; Gamma; end\n"
      write "#{root}/app/c/gamma.rb", "class Gamma; Delta; end\n"
      write "#{root}/app/d/delta.rb", "class Delta; Gamma; end\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :a, in: 'app/a/**/*.rb'
        component :b, in: 'app/b/**/*.rb'
        component :c, in: 'app/c/**/*.rb'
        component :d, in: 'app/d/**/*.rb'
        no_cycles
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['component dependency cycle: a -> b -> a', 'component dependency cycle: c -> d -> c'],
                   diagnostics.map(&:message).sort
    end
  end

  def test_dependency_rules_see_assigned_constants
    with_project do |root|
      write "#{root}/app/models/billing.rb", <<~RUBY
        class Billing
          MAX_RETRIES = 3
        end
      RUBY
      write "#{root}/app/services/charge.rb", <<~RUBY
        class Charge
          def run = Billing::MAX_RETRIES
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :services, in: 'app/services/**/*.rb'
        services.cannot_use :models
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'Charge references Billing::MAX_RETRIES', diagnostics.first.evidence
    end
  end

  def test_protocols_apply_to_struct_classes_but_not_plain_constants
    with_project do |root|
      write "#{root}/app/services/currency.rb", <<~RUBY
        Currency = Struct.new(:code) do
          def call = code
        end

        TIMEOUT = 5
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.must_implement :call
      end

      assert_empty diagnostics_for(definition, root)
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

  def test_cannot_call_treats_association_readers_as_own_api
    with_project do |root|
      write "#{root}/app/models/preview_authorization.rb", <<~RUBY
        class PreviewAuthorization < ApplicationRecord
          belongs_to :session
          has_many :flashes

          def valid_session?
            session&.user && flashes.any? && build_session && create_session! && reload_session
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :session, receiver: :none
        models.cannot_call :flashes, receiver: :none
        models.cannot_call :build_session, receiver: :none
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_cannot_call_still_flags_a_name_no_macro_defines
    with_project do |root|
      write "#{root}/app/models/preview_authorization.rb", <<~RUBY
        class PreviewAuthorization < ApplicationRecord
          belongs_to :account

          def valid_session?
            session&.user
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :session, receiver: :none
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'models must not call #session', diagnostics.first.message
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

  def test_concern_independence_allows_reference_to_its_own_constants
    with_project do |root|
      write "#{root}/app/models/widget.rb", <<~RUBY
        class Widget
          include Naming
        end
      RUBY

      write "#{root}/app/models/concerns/widget/naming.rb", <<~RUBY
        class Widget
          module Naming
            DEFAULT = "x"

            def name_or_default
              DEFAULT
            end
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :concerns, in: 'app/models/concerns/**/*.rb'
        concerns.cannot_reference_includers
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_concern_independence_flags_reference_to_constants_owned_by_includer
    with_project do |root|
      write "#{root}/app/models/widget.rb", <<~RUBY
        class Widget
          DEFAULT = "x"
          include Naming
        end
      RUBY

      write "#{root}/app/models/concerns/widget/naming.rb", <<~RUBY
        class Widget
          module Naming
            def name_or_default
              Widget::DEFAULT
            end
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :concerns, in: 'app/models/concerns/**/*.rb'
        concerns.cannot_reference_includers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/Widget::Naming must not reference its includer Widget/, diagnostics.first.message)
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
      assert_equal 'services must stay empty', diagnostics.first.message
      assert_equal 'behavior belongs on models', diagnostics.first.reason
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

  def test_namespace_only_reopenings_do_not_claim_the_constant
    with_project do |root|
      write "#{root}/app/models/project.rb", <<~RUBY
        class Project
          def active? = true
        end
      RUBY

      write "#{root}/app/jobs/project/expiration_job.rb", <<~RUBY
        class Project
          class ExpirationJob
            def perform = nil
          end
        end
      RUBY

      write "#{root}/app/services/project_archiver.rb", <<~RUBY
        class ProjectArchiver
          def call
            Project.new
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :jobs, in: 'app/jobs/**/*.rb'
        component :services, in: 'app/services/**/*.rb'
        services.can_only_use :models
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_namespace_without_real_definition_still_belongs_to_its_component
    with_project do |root|
      write "#{root}/app/services/payments/charge.rb", <<~RUBY
        module Payments
          class Charge
            def call = nil
          end
        end
      RUBY

      write "#{root}/app/models/invoice.rb", <<~RUBY
        class Invoice
          Payments
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :services, in: 'app/services/**/*.rb'
        models.cannot_use :services
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/models must not depend on services/, diagnostics.first.message)
    end
  end
end
