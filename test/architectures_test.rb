# frozen_string_literal: true

require 'test_helper'

class ArchitecturesTest < ArchSpecTest
  def test_rails_architecture_keeps_models_away_from_controllers
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          UsersController
          render :show
        end
      RUBY
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        architecture :rails
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/models must not depend on controllers/) })
      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/models must not call #render/) })
    end
  end

  def test_rails_strict_flags_concern_referencing_its_includer
    with_project do |root|
      write "#{root}/app/models/concerns/chargeable.rb", <<~RUBY
        module Chargeable
          def charge
            Order.sum(:total)
          end
        end
      RUBY
      write "#{root}/app/models/order.rb", <<~RUBY
        class Order < ApplicationRecord
          include Chargeable
        end
      RUBY

      definition = ArchSpec.define do
        architecture :rails_strict
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? do |diagnostic|
        diagnostic.rule == 'concerns.independence' &&
          diagnostic.message == 'Chargeable must not reference its includer Order'
      end)
    end
  end

  def test_vanilla_rails_allows_controllers_to_include_concerns
    with_project do |root|
      write "#{root}/app/controllers/concerns/authentication.rb", <<~RUBY
        module Authentication
          def current_user
            User.find_by(id: session[:user_id])
          end
        end
      RUBY
      write "#{root}/app/controllers/application_controller.rb", <<~RUBY
        class ApplicationController < ActionController::Base
          include Authentication
        end
      RUBY

      definition = ArchSpec.define do
        architecture :vanilla_rails
      end

      dependency_diagnostics = diagnostics_for(definition, root).select do |diagnostic|
        diagnostic.rule.start_with?('dependencies')
      end

      assert_empty dependency_diagnostics,
        'controllers may include concerns in vanilla Rails'
    end
  end

  def test_rails_share_helpers_allows_models_to_use_helpers
    with_project do |root|
      write "#{root}/app/models/report.rb", "class Report; MoneyHelper; end\n"
      write "#{root}/app/helpers/money_helper.rb", "module MoneyHelper; end\n"

      strict = ArchSpec.define { architecture :rails }
      relaxed = ArchSpec.define { architecture :rails, share_helpers: true }

      assert(diagnostics_for(strict, root).any? { |d| d.message =~ /models must not depend on helpers/ })
      assert_empty diagnostics_for(relaxed, root).select { |d| d.rule.start_with?('dependencies') }
    end
  end

  def test_modular_monolith_public_option_enforces_privacy
    with_project do |root|
      write "#{root}/packs/billing/app/public/billing/invoicer.rb", <<~RUBY
        module Billing
          class Invoicer; end
        end
      RUBY
      write "#{root}/packs/billing/app/models/billing/ledger.rb", <<~RUBY
        module Billing
          class Ledger; end
        end
      RUBY
      write "#{root}/packs/catalog/app/models/product.rb", <<~RUBY
        class Product
          Billing::Invoicer
          Billing::Ledger
        end
      RUBY

      definition = ArchSpec.define do
        source 'packs/*/app/**/*.rb'
        architecture :modular_monolith,
                     components: {
                       billing: 'packs/billing/**/*.rb',
                       catalog: 'packs/catalog/**/*.rb'
                     },
                     allow: { catalog: %i[billing] },
                     public: { billing: 'packs/billing/app/public/**/*.rb' }
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['dependencies.privacy'], diagnostics.map(&:rule)
      assert_match(/Billing::Ledger is private to billing/, diagnostics.first.message)
    end
  end

  def test_layered_architecture_enforces_inward_dependencies
    with_project do |root|
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"

      definition = ArchSpec.define do
        architecture :layered, layers: {
          interface: 'app/controllers/**/*.rb',
          domain: 'app/models/**/*.rb'
        }
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['dependencies.allow'], diagnostics.map(&:rule).uniq
      assert_match(/domain may not depend on interface/, diagnostics.first.message)
    end
  end

  def test_hexagonal_architecture_keeps_domain_away_from_adapters
    with_project do |root|
      write "#{root}/app/domain/order.rb", "class Order; PaymentGatewayAdapter; end\n"
      write "#{root}/app/adapters/payment_gateway_adapter.rb", "class PaymentGatewayAdapter; Order; end\n"

      definition = ArchSpec.define do
        architecture :hexagonal,
                     domain: 'app/domain/**/*.rb',
                     ports: 'app/ports/**/*.rb',
                     adapters: 'app/adapters/**/*.rb',
                     application: 'app/services/**/*.rb'
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/domain must not depend on adapters/) })
    end
  end

  def test_clean_architecture_keeps_entities_inward
    with_project do |root|
      write "#{root}/app/entities/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; User; end\n"

      definition = ArchSpec.define do
        architecture :clean,
                     frameworks: 'app/controllers/**/*.rb',
                     interface_adapters: 'app/adapters/**/*.rb',
                     use_cases: 'app/use_cases/**/*.rb',
                     entities: 'app/entities/**/*.rb'
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/entities may not depend on frameworks/) })
    end
  end

  def test_modular_monolith_enforces_declared_dependencies
    with_project do |root|
      write "#{root}/packs/billing/app/models/invoice.rb", "class Invoice; Product; Money; end\n"
      write "#{root}/packs/catalog/app/models/product.rb", "class Product; end\n"
      write "#{root}/packs/shared/app/models/money.rb", "class Money; end\n"

      definition = ArchSpec.define do
        architecture :modular_monolith,
                     components: {
                       billing: 'packs/billing/**/*.rb',
                       catalog: 'packs/catalog/**/*.rb',
                       shared: 'packs/shared/**/*.rb'
                     },
                     allow: {
                       billing: %i[shared],
                       catalog: %i[shared]
                     }
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/billing may not depend on catalog/, diagnostics.first.message)
    end
  end

  def test_cqrs_architecture_separates_commands_and_queries
    with_project do |root|
      write "#{root}/app/commands/create_invoice.rb", "class CreateInvoice; InvoiceQuery; end\n"
      write "#{root}/app/queries/invoice_query.rb", <<~RUBY
        class InvoiceQuery
          def results
            CreateInvoice
            update!
          end
        end
      RUBY

      definition = ArchSpec.define do
        architecture :cqrs,
                     commands: 'app/commands/**/*.rb',
                     queries: 'app/queries/**/*.rb'
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/commands must not depend on queries/) })
      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/queries must not depend on commands/) })
      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/queries must not call #update!/) })
    end
  end

  def test_event_driven_architecture_keeps_events_passive
    with_project do |root|
      write "#{root}/app/events/user_created.rb", "class UserCreated; AuditSubscriber; end\n"
      write "#{root}/app/subscribers/audit_subscriber.rb", "class AuditSubscriber; UserCreated; end\n"
      write "#{root}/app/publishers/user_publisher.rb", "class UserPublisher; UserCreated; end\n"

      definition = ArchSpec.define do
        architecture :event_driven,
                     events: 'app/events/**/*.rb',
                     publishers: 'app/publishers/**/*.rb',
                     subscribers: 'app/subscribers/**/*.rb'
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/events must not depend on subscribers/) })
    end
  end

  def test_architectures_use_rails_defaults
    with_project do |root|
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; User; end\n"
      write "#{root}/app/models/user.rb", "class User; end\n"

      definition = ArchSpec.define do
        architecture :layered
        architecture :cqrs
        architecture :event_driven
      end

      diagnostics = diagnostics_for(definition, root)

      assert_empty diagnostics
    end
  end

  def test_vanilla_rails_architecture_forbids_service_objects
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/app/services/create_user.rb", "class CreateUser; end\n"
      write "#{root}/app/policies/user_policy.rb", "class UserPolicy; end\n"

      definition = ArchSpec.define do
        architecture :vanilla_rails
      end

      diagnostics = diagnostics_for(definition, root)
      messages = diagnostics.map(&:message)

      assert_equal ['components.empty'], diagnostics.map(&:rule).uniq
      assert(messages.any? { |message| message.match?(/services must stay empty/) })
      assert(messages.any? { |message| message.match?(/policies must stay empty/) })
    end
  end

  def test_vanilla_rails_architecture_passes_a_vanilla_app
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; User; end\n"

      definition = ArchSpec.define do
        architecture :vanilla_rails
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_rails_strict_architecture_adds_cycle_and_concern_checks
    definition = ArchSpec.define do
      architecture :rails_strict
    end

    rule_names = definition.rules.map(&:class).map(&:name)

    assert_includes rule_names, 'ArchSpec::Rules::NoCyclesRule'
    assert_includes rule_names, 'ArchSpec::Rules::ConcernIndependenceRule'
  end

  def test_ruby_conventions_bans_get_set_and_is_prefixes
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def get_name; @name; end
          def set_name(value); @name = value; end
          def is_admin; role == :admin; end
          def has_role?(role); end
          def name; @name; end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        architecture :ruby_conventions
      end

      diagnostics = diagnostics_for(definition, root)

      flagged = diagnostics.map { |diagnostic| diagnostic.message[/#\w+/] }.sort
      assert_equal ['#get_name', '#is_admin', '#set_name'], flagged
      assert(diagnostics.all? { |diagnostic| diagnostic.rule == 'naming.forbidden' })
      assert(diagnostics.all? { |diagnostic| diagnostic.confidence == :high })
    end
  end

  def test_ruby_conventions_checks_class_methods_too
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def self.get_name; end

          class << self
            def is_admin?; end
          end
        end
      RUBY

      definition = ArchSpec.define do
        architecture :ruby_conventions
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal %w[get_name is_admin?], diagnostics.map { |diagnostic| diagnostic.evidence[/method (\S+)/, 1] }.sort
      assert(diagnostics.all? { |diagnostic| diagnostic.evidence.include?('class method') })
    end
  end

  def test_preset_is_an_alias_for_architecture
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; def get_name; @name; end; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        preset :ruby_conventions
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.rule == 'naming.forbidden' })
    end
  end

  def test_rails_architecture_requires_controllers_and_models
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        architecture :rails, components: { controllers: 'app/controllers/**/*.rb' }
      end
    end

    assert_match(/need controllers and models components, missing: models/, error.message)
  end

  def test_rails_architecture_skips_rules_for_omitted_optional_components
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; User; end\n"

      definition = ArchSpec.define do
        architecture :rails, components: {
          controllers: 'app/controllers/**/*.rb',
          models: 'app/models/**/*.rb'
        }
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['dependencies.forbid'], diagnostics.map(&:rule)
      assert_match(/models must not depend on controllers/, diagnostics.first.message)
    end
  end

  def test_architectures_reject_unknown_options
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define { architecture :rails, typo: true }
    end

    assert_match(/unknown option.*typo:/, error.message)
  end

  def test_modular_monolith_requires_components
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define { architecture :modular_monolith }
    end

    assert_match(/requires the components: option/, error.message)
  end

  def test_ruby_conventions_composes_with_rails
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def get_name; @name; end
          UsersController
        end
      RUBY
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        architecture :rails
        architecture :ruby_conventions
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.rule == 'naming.forbidden' })
      assert(diagnostics.any? { |diagnostic| diagnostic.message.match?(/models must not depend on controllers/) })
    end
  end
end
