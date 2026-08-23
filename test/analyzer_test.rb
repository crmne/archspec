# frozen_string_literal: true

require 'test_helper'

class AnalyzerTest < ArchSpecTest
  def test_compact_class_paths_join_the_enclosing_namespace
    with_project do |root|
      write "#{root}/app/controllers/admin/users/roles_controller.rb", <<~RUBY
        module Admin
          class Users::RolesController
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :controllers, in: 'app/controllers/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_includes graph.constants.map(&:name), 'Admin::Users::RolesController'
    end
  end

  def test_dynamic_superclasses_and_constant_paths_do_not_crash
    with_project do |root|
      {
        money: 'class Money < Data.define(:cents); end',
        result: 'class Result < Struct.new(:ok); end',
        widget: 'class Widget < Object.const_get("ApplicationRecord"); end',
        thing: 'class Thing < superclass::Base; end',
        spot: 'class Spot; self.class::ORIGIN; end'
      }.each do |name, source|
        write "#{root}/app/models/#{name}.rb", "#{source}\n"
      end

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal %w[Money Result Spot Thing Widget], graph.constants.map(&:name).sort
      refute graph.edges.any? { |edge| edge.type == :inherits_from }
    end
  end

  def test_incomplete_constant_paths_become_parse_diagnostics_instead_of_crashes
    with_project do |root|
      write "#{root}/app/models/broken.rb", <<~RUBY
        class Broken
          Foo::
        end

        class AlsoBroken::
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      diagnostics = diagnostics_for(definition, root)

      assert diagnostics.any?
      assert diagnostics.all? { |diagnostic| diagnostic.rule == 'parser.syntax' }
    end
  end

  def test_resolves_constants_from_the_recorded_lexical_nesting
    with_project do |root|
      write "#{root}/app/orders/order.rb", <<~RUBY
        module Domain
          class Order
            Entry
          end
        end
      RUBY
      write "#{root}/app/entries/entry.rb", "class Domain::Order::Entry; end\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :orders, in: 'app/orders/**/*.rb'
        component :entries, in: 'app/entries/**/*.rb'
        orders.cannot_use :entries
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/Entry/, diagnostics.first.evidence)
    end
  end

  def test_absolute_constant_references_do_not_resolve_lexically
    with_project do |root|
      write "#{root}/app/global/user.rb", "class User; end\n"
      write "#{root}/app/domain/user.rb", "class Domain::User; end\n"
      write "#{root}/app/domain/service.rb", <<~RUBY
        class Domain::Service
          ::User
        end
      RUBY

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :global, in: 'app/global/**/*.rb'
        component :domain, in: 'app/domain/**/*.rb'
        domain.cannot_use :global
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/::User/, diagnostics.first.evidence)
    end
  end

  def test_superclasses_resolve_in_the_enclosing_lexical_nesting
    with_project do |root|
      write "#{root}/app/base/base.rb", "class Domain::Base; end\n"
      write "#{root}/app/children/child.rb", <<~RUBY
        module Domain
          class Child < Base
          end
        end
      RUBY
      write "#{root}/app/nested/base.rb", "class Domain::Child::Base; end\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :base, in: 'app/base/**/*.rb'
        component :children, in: 'app/children/**/*.rb'
        component :nested, in: 'app/nested/**/*.rb'
        children.cannot_use :base, :nested
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/children must not depend on base/, diagnostics.first.message)
    end
  end

  def test_each_directory_declares_a_component_per_subdirectory
    with_project do |root|
      write "#{root}/engines/billing/app/models/invoice.rb", "class Invoice; end\n"
      write "#{root}/engines/catalog/app/models/product.rb", "class Product; end\n"
      write "#{root}/engines/README.md", "not a ruby dir but should be skipped fine\n"

      definition = ArchSpec.define do
        self.base_dir = root
        source 'engines/*/app/**/*.rb'
        each_directory 'engines/*' do |name, path|
          component name, in: "#{path}/**/*.rb"
        end
      end

      assert_equal %i[billing catalog], definition.component_specs.keys.sort
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      assert_includes graph.component_names_for_path("#{root}/engines/billing/app/models/invoice.rb"), :billing
    end
  end

  def test_ignore_patterns_remove_files_even_when_a_component_matches_them
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/app/models/legacy/account.rb", "class Legacy::Account; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        ignore 'app/models/legacy/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal ['User'], graph.constants.map(&:name)
      assert_equal ["#{root}/app/models/user.rb"], graph.files.keys
    end
  end

  def test_records_require_and_dynamic_feature_facts
    with_project do |root|
      write "#{root}/lib/loader.rb", <<~RUBY
        require "json"
        require_relative "support"
        Kernel.require "set"
        Object.const_get("User")
      RUBY

      definition = ArchSpec.define { source 'lib/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert graph.edges.any? { |edge| edge.type == :requires && edge.to == 'json' }
      assert graph.edges.any? { |edge| edge.type == :requires_relative && edge.to == 'support' }
      refute graph.edges.any? { |edge| edge.type == :requires && edge.to == 'set' }
      assert(graph.edges.any? do |edge|
        edge.type == :dynamic_feature && edge.to == 'const_get' &&
          edge.confidence == :unknown_due_to_dynamic_feature
      end)
    end
  end

  def test_constant_selectors_do_not_claim_unmatched_constants_in_the_same_file
    with_project do |root|
      write "#{root}/app/models/mixed.rb", <<~RUBY
        class Before; end
        class Selected; end
        class After; end
      RUBY

      definition = ArchSpec.define do
        component :selected, constants: 'Selected'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      component = graph.components.fetch(:selected)

      assert_equal ['Selected'], component.constants.to_a
      assert_equal ["#{root}/app/models/mixed.rb"], component.files.to_a
    end
  end

  def test_namespace_selectors_claim_the_namespace_and_its_children
    with_project do |root|
      write "#{root}/app/models/mixed.rb", <<~RUBY
        module Billing
          class Invoice; end
        end
        class Other; end
      RUBY

      definition = ArchSpec.define do
        component :billing, namespace: 'Billing'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal %w[Billing Billing::Invoice], graph.components.fetch(:billing).constants.to_a.sort
    end
  end

  def test_constant_selectors_only_attribute_matching_constants_edges
    with_project do |root|
      write "#{root}/app/models/mixed.rb", <<~RUBY
        class Selected
          Forbidden
        end
        class Other
          Forbidden
        end
      RUBY
      write "#{root}/app/forbidden/forbidden.rb", "class Forbidden; end\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :selected, constants: 'Selected'
        component :forbidden, in: 'app/forbidden/**/*.rb'
        selected.cannot_use :forbidden
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/Selected references Forbidden/, diagnostics.first.evidence)
    end
  end

  def test_tracks_method_visibility_across_declaration_forms
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def pub; end
          private def inline; end
          def after_inline; end
          private attr_reader :inline_private_attr
          def after_private_attr; end
          private
          def bare_private; end
          public
          def repub; end
          private :repub
          private
          attr_reader :priv_attr
          public attr_reader :inline_public_attr
          def after_inline_attr; end
          def self.klass; end
          private_class_method :klass
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      visibility = graph.constants_named('User').first.method_definitions.each_with_object({}) do |method, map|
        map[[method.name, method.scope]] = method.visibility
      end

      assert_equal :public, visibility[[:pub, :instance]]
      assert_equal :private, visibility[[:inline, :instance]]
      assert_equal :public, visibility[[:after_inline, :instance]]
      assert_equal :private, visibility[[:inline_private_attr, :instance]]
      assert_equal :public, visibility[[:after_private_attr, :instance]]
      assert_equal :private, visibility[[:bare_private, :instance]]
      assert_equal :private, visibility[[:repub, :instance]]
      assert_equal :private, visibility[[:priv_attr, :instance]]
      assert_equal :public, visibility[[:inline_public_attr, :instance]]
      assert_equal :private, visibility[[:after_inline_attr, :instance]]
      assert_equal :private, visibility[[:klass, :class]]
    end
  end

  def test_singleton_class_defs_are_class_methods_with_visibility
    with_project do |root|
      write "#{root}/app/models/agent.rb", <<~RUBY
        class Agent
          def instance_pub; end

          class << self
            def create; end

            private

            def with_rails_chat_record; end
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      methods = graph.constants_named('Agent').first.method_definitions.each_with_object({}) do |method, map|
        map[method.name] = [method.scope, method.visibility]
      end

      assert_equal %i[instance public], methods[:instance_pub]
      assert_equal %i[class public], methods[:create]
      assert_equal %i[class private], methods[:with_rails_chat_record]
    end
  end

  def test_methods_defined_on_other_or_unknown_singletons_are_not_attributed_to_the_enclosing_class
    with_project do |root|
      write "#{root}/app/models/owner.rb", <<~RUBY
        class Owner
          def Other.get_config; end

          target = Object.new
          class << target
            def get_state; end
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      owner = graph.constants_named('Owner').first

      assert_empty owner.instance_methods
      assert_empty owner.class_methods
    end
  end

  def test_tracks_methods_generated_by_rails_attribute_macros
    with_project do |root|
      write "#{root}/app/models/current.rb", <<~RUBY
        class Current < ::ActiveSupport::CurrentAttributes
          attribute :session, :user
        end

        class Product < ApplicationRecord
          attribute :price, :decimal
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal %i[session session= user user=], graph.constants_named('Current').first.instance_methods.to_a.sort
      assert_equal %i[price price=], graph.constants_named('Product').first.instance_methods.to_a.sort
    end
  end

  def test_constant_assignments_define_constants
    with_project do |root|
      write "#{root}/app/models/billing.rb", <<~RUBY
        class Billing
          MAX_RETRIES = 3
          Currency = Struct.new(:code) do
            def call = code
          end
          Events = Module.new
          Fallback = Class.new(StandardError)
        end

        DEFAULT_RATE = 0.1
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal :constant, graph.constants_named('Billing::MAX_RETRIES').first.kind
      assert_equal :constant, graph.constants_named('DEFAULT_RATE').first.kind
      assert_equal :module, graph.constants_named('Billing::Events').first.kind

      currency = graph.constants_named('Billing::Currency').first
      assert_equal :class, currency.kind
      assert_equal 'Struct.new', currency.superclass
      assert_equal %i[call], currency.instance_methods.to_a

      fallback = graph.constants_named('Billing::Fallback').first
      assert_equal :class, fallback.kind
      assert_equal 'StandardError', fallback.superclass
    end
  end

  def test_builds_graph_from_direct_prism_parse
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User < ApplicationRecord
          include Billable

          def call
            Billing::Invoice.new
          end
        end
      RUBY

      write "#{root}/app/models/billing/invoice.rb", <<~RUBY
        module Billing
          class Invoice
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal ['Billing', 'Billing::Invoice', 'User'], graph.constants.map(&:name).sort
      assert_equal ['User'], graph.constants_named('User').map(&:name)
      assert(graph.edges.any? { |edge| edge.type == :inherits_from && edge.to == 'ApplicationRecord' })
      assert(graph.edges.any? { |edge| edge.type == :includes && edge.to == 'Billable' })
      assert(graph.edges.any? { |edge| edge.type == :references_constant && edge.to == 'Billing::Invoice' })
      assert_equal [:models], graph.component_names_for_path("#{root}/app/models/user.rb").to_a
    end
  end

  def test_except_removes_files_from_what_in_matched
    with_project do |root|
      write "#{root}/app/models/order.rb", "class Order; end\n"
      write "#{root}/app/models/checkout_workflow.rb", "class CheckoutWorkflow; end\n"

      definition = ArchSpec.define do
        component :domain, in: 'app/models/**/*.rb', except: 'app/models/**/*_workflow.rb'
        component :workflows, in: 'app/models/**/*_workflow.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      domain = graph.components[:domain]
      workflows = graph.components[:workflows]

      assert_equal [File.join(root, 'app/models/order.rb')], domain.files.to_a
      assert_equal Set['Order'], domain.constants
      assert_equal Set['CheckoutWorkflow'], workflows.constants
      assert_equal ['excluded by except pattern app/models/**/*_workflow.rb'],
                   domain.exclusion_reasons[File.join(root, 'app/models/checkout_workflow.rb')].to_a
    end
  end

  def test_except_leaves_namespace_and_constant_selectors_alone
    with_project do |root|
      write "#{root}/app/models/billing/invoice_workflow.rb", "module Billing; class InvoiceWorkflow; end; end\n"

      definition = ArchSpec.define do
        component :billing, in: 'app/models/**/*.rb', except: 'app/models/**/*_workflow.rb', namespace: 'Billing'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      billing = graph.components[:billing]

      assert billing.includes_constant?('Billing::InvoiceWorkflow')
      assert billing.files.include?(File.join(root, 'app/models/billing/invoice_workflow.rb'))
    end
  end

  def test_except_without_in_is_refused_at_declaration
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :domain, except: 'app/models/**/*_workflow.rb'
      end
    end

    assert_match(/except: but no in:/, error.message)
  end

  def test_a_file_the_component_still_claims_is_not_listed_as_excluded
    with_project do |root|
      write "#{root}/app/models/billing/invoice_workflow.rb", "module Billing; class InvoiceWorkflow; end; end\n"

      definition = ArchSpec.define do
        component :billing, in: 'app/models/**/*.rb', except: 'app/models/**/*_workflow.rb', namespace: 'Billing'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      path = File.join(root, 'app/models/billing/invoice_workflow.rb')

      assert_equal({}, graph.component_exclusion_reasons_for_path(path))
      assert_includes graph.component_assignment_reasons_for_path(path)[:billing], 'defines Billing::InvoiceWorkflow'
    end
  end

  def test_except_patterns_merge_across_repeated_declarations
    with_project do |root|
      write "#{root}/app/models/order.rb", "class Order; end\n"
      write "#{root}/app/models/checkout_workflow.rb", "class CheckoutWorkflow; end\n"
      write "#{root}/app/models/legacy_report.rb", "class LegacyReport; end\n"

      definition = ArchSpec.define do
        component :domain, in: 'app/models/**/*.rb', except: 'app/models/**/*_workflow.rb'
        component :domain, except: 'app/models/legacy_*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal Set['Order'], graph.components[:domain].constants
    end
  end
end
