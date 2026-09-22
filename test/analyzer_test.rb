# frozen_string_literal: true

require 'test_helper'

class AnalyzerTest < ArchSpecTest
  def test_erb_prism_roots_report_dependencies_and_calls_at_template_positions
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      path = "#{root}/app/views/index.html.erb"
      write path, <<~ERB
        <h1>Users</h1>
          <%= User.count %>
        <%
          User.count
        %>
        <% if User.count %>
            <%= User.count %>
        <% end %>
        <%= User %>
      ERB
      definition = ArchSpec.define do
        component :views, in: 'app/views/**/*.erb'
        component :models, in: 'app/models/**/*.rb'
        views.cannot_use :models
        views.cannot_call :count
      end

      diagnostics = diagnostics_for(definition, root)
      dependencies = diagnostics.select { |diagnostic| diagnostic.rule == 'dependencies.forbid' }
      calls = diagnostics.select { |diagnostic| diagnostic.rule == 'methods.forbid' }

      assert_equal [
        ArchSpec::SourceLocation.new(path, 2, 7, 2, 11),
        ArchSpec::SourceLocation.new(path, 4, 3, 4, 7),
        ArchSpec::SourceLocation.new(path, 6, 7, 6, 11),
        ArchSpec::SourceLocation.new(path, 7, 9, 7, 13),
        ArchSpec::SourceLocation.new(path, 9, 5, 9, 9)
      ], dependencies.map(&:location)
      assert_equal [
        ArchSpec::SourceLocation.new(path, 2, 7, 2, 17),
        ArchSpec::SourceLocation.new(path, 4, 3, 4, 13),
        ArchSpec::SourceLocation.new(path, 6, 7, 6, 17),
        ArchSpec::SourceLocation.new(path, 7, 9, 7, 19)
      ], calls.map(&:location)
    end
  end

  def test_malformed_ruby_in_erb_reports_syntax_errors_with_template_locations
    with_project do |root|
      path = "#{root}/app/views/index.html.erb"
      write path, "<div>\n  <%= User.count) %>\n"
      definition = ArchSpec.define do
        component :views, in: 'app/views/**/*.erb'
      end

      diagnostics = diagnostics_for(definition, root)

      refute_empty diagnostics
      diagnostics.each do |diagnostic|
        assert_equal 'parser.syntax', diagnostic.rule
        assert_equal ArchSpec::SourceLocation.new(path, 2, 17, 2, 18), diagnostic.location
      end
    end
  end

  def test_erb_same_line_suppressions_and_ruby_comment_extraction_limits
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      path = "#{root}/app/views/index.html.erb"
      write path, <<~ERB
        <%# archspec:disable-line dependencies.forbid -- before %><%= User.count %>
        <%= User.count %><%# archspec:disable-line dependencies.forbid -- after %>
        <% # archspec:disable-line dependencies.forbid %><%= User.count %>
        <%= User.count %><% # archspec:disable-line dependencies.forbid %>
        <%= User.count # archspec:disable-line dependencies.forbid
        %>
        <%= User.count %>
      ERB
      definition = ArchSpec.define do
        component :views, in: 'app/views/**/*.erb'
        component :models, in: 'app/models/**/*.rb'
        views.cannot_use :models
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal [3, 4, 7], diagnostics.map { |diagnostic| diagnostic.location.line }
      # Herb omits the single-line Ruby comments but retains the adjacent expressions.
      assert_equal [1, 2, 3, 4, 5, 7],
                   graph.edges.select { |edge| edge.to == 'User' }.map { |edge| edge.location.line }
      assert_equal [
        ArchSpec::Suppression.new('dependencies.forbid', 1, 1, 'before'),
        ArchSpec::Suppression.new('dependencies.forbid', 2, 2, 'after'),
        ArchSpec::Suppression.new('dependencies.forbid', 5, 5, nil)
      ], graph.files.fetch(path).suppressions
    end
  end

  def test_erb_mixed_comment_blocks_are_sorted_by_template_position
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      path = "#{root}/app/views/index.html.erb"
      write path, <<~ERB
        <%# archspec:disable dependencies.forbid -- outer %><% # archspec:disable dependencies.forbid -- inner
        %>
        <%= User.count %>
        <%# archspec:enable dependencies.forbid %>
        <%= User.count %>
        <% # archspec:enable dependencies.forbid
        %><%= User.count %>
        <% # archspec:disable dependencies.forbid -- ruby first
        %><%# archspec:enable dependencies.forbid %>
        <%= User.count %>
        <%# archspec:enable dependencies.forbid %>
      ERB
      definition = ArchSpec.define do
        component :views, in: 'app/views/**/*.erb'
        component :models, in: 'app/models/**/*.rb'
        views.cannot_use :models
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal [7, 10], diagnostics.map { |diagnostic| diagnostic.location.line }
      assert_equal [
        ArchSpec::Suppression.new('dependencies.forbid', 1, 3, 'inner'),
        ArchSpec::Suppression.new('dependencies.forbid', 1, 5, 'outer'),
        ArchSpec::Suppression.new('dependencies.forbid', 8, 8, 'ruby first')
      ], graph.files.fetch(path).suppressions
    end
  end

  def test_erb_wildcard_and_omitted_rules_suppress_through_eof
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      expression = "<%= User.count.to_s %>\n"
      write "#{root}/app/views/wildcard.html.erb", expression
      definition = ArchSpec.define do
        component :views, in: 'app/views/**/*.erb'
        component :models, in: 'app/models/**/*.rb'
        views.cannot_use :models
        views.cannot_call :count
      end

      assert_equal %w[dependencies.forbid methods.forbid], diagnostics_for(definition, root).map(&:rule).sort

      write "#{root}/app/views/wildcard.html.erb",
            "<%# archspec:disable * -- accepted boundary %>\n#{expression}"
      write "#{root}/app/views/omitted.html.erb",
            "<% # archspec:disable -- accepted boundary\n%>\n#{expression}"
      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_empty ArchSpec::Evaluator.evaluate(definition, graph)
      %w[wildcard omitted].each do |name|
        assert_equal [ArchSpec::Suppression.new(nil, 1, Float::INFINITY, 'accepted boundary')],
                     graph.files.fetch("#{root}/app/views/#{name}.html.erb").suppressions
      end
    end
  end

  def test_erb_ordinary_comments_and_directive_like_strings_are_not_analyzed_as_suppressions
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      path = "#{root}/app/views/index.html.erb"
      write path, <<~ERB
        <%# User.count %>
        <%# ordinary comment text %>
        <% # just a Ruby comment %>
        <!-- archspec:disable dependencies.forbid -->
        <%= '# archspec:disable dependencies.forbid' %>
        <%= 'archspec:disable dependencies.forbid' %>
        <%= User.count %>
      ERB
      definition = ArchSpec.define do
        component :views, in: 'app/views/**/*.erb'
        component :models, in: 'app/models/**/*.rb'
        views.cannot_use :models
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_empty graph.files.fetch(path).suppressions
      assert_equal [7], diagnostics.map { |diagnostic| diagnostic.location.line }
      assert_equal [7], graph.edges.select { |edge| edge.to == 'User' }.map { |edge| edge.location.line }
    end
  end

  def test_erb_multiline_comments_and_control_flow_comments_use_physical_lines
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      path = "#{root}/app/views/index.html.erb"
      write path, <<~ERB
        <%# ordinary first line
          archspec:disable-next-line dependencies.forbid -- closing tag
        %>
        <%= User.count %>
        <%# archspec:disable-next-line dependencies.forbid %>

        <%= User.count %>
        <%# ordinary first line
          archspec:disable-next-line dependencies.forbid -- after multiline %>
        <%= User.count %>
        <% if true # archspec:disable-next-line dependencies.forbid -- control flow
          User.count
        %>
        <%= User.count %>
        <% end %>
      ERB
      definition = ArchSpec.define do
        component :views, in: 'app/views/**/*.erb'
        component :models, in: 'app/models/**/*.rb'
        views.cannot_use :models
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal [4, 7, 14], diagnostics.map { |diagnostic| diagnostic.location.line }
      assert_equal [
        ArchSpec::Suppression.new('dependencies.forbid', 3, 3, 'closing tag'),
        ArchSpec::Suppression.new('dependencies.forbid', 6, 6, nil),
        ArchSpec::Suppression.new('dependencies.forbid', 10, 10, 'after multiline'),
        ArchSpec::Suppression.new('dependencies.forbid', 12, 12, 'control flow')
      ], graph.files.fetch(path).suppressions
    end
  end

  def test_rake_sources_report_dependencies_and_honor_ignores
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/lib/tasks/cleanup.rake", "task :cleanup do\n  User.delete_all\nend\n"
      write "#{root}/lib/tasks/ignored.rake", "User.delete_all\n"
      write "#{root}/lib/tasks/template.erb", '<%= User.count %>'

      definition = ArchSpec.define do
        source 'app/**/*.rb', 'lib/tasks/**/*'
        ignore 'lib/tasks/ignored.rake'
        component :models, in: 'app/models/**/*.rb'
        component :tasks, in: 'lib/tasks/**/*.rake'
        tasks.cannot_use :models
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)

      assert_equal %w[app/models/user.rb lib/tasks/cleanup.rake lib/tasks/template.erb],
                   graph.files.values.map(&:relative_path)
      assert_equal ['dependencies.forbid'], diagnostics.map(&:rule)
      assert_equal 2, diagnostics.first.location.line
      assert_equal 3, diagnostics.first.location.column
      assert_equal 'lib/tasks/cleanup.rake references User', diagnostics.first.evidence
    end
  end

  def test_rake_component_patterns_select_files_and_report_syntax_errors
    with_project do |root|
      write "#{root}/lib/tasks/broken.rake", "task :broken do\n"
      definition = ArchSpec.define do
        component :tasks, in: 'lib/tasks/**/*.rake'
      end

      diagnostics = diagnostics_for(definition, root)
      refute_empty diagnostics
      assert diagnostics.all? { |diagnostic| diagnostic.rule == 'parser.syntax' }
      assert diagnostics.all? { |diagnostic| diagnostic.location.path.end_with?('/broken.rake') }
    end
  end

  def test_compact_class_paths_join_the_enclosing_namespace
    with_project do |root|
      write "#{root}/app/controllers/admin/users/roles_controller.rb", <<~RUBY
        module Admin
          module Trackable
          end

          class BaseController
          end

          class Users::RolesController < BaseController
            TOKEN = :ok
            include Trackable

            def index = :ok
            private :index
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :controllers, in: 'app/controllers/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_includes graph.constants.map(&:name), 'Admin::Users::RolesController'
      controller = graph.constants_named('Admin::Users::RolesController').first
      assert_includes controller.instance_methods, :index
      assert_equal :private, controller.method_definitions.find { |method| method.name == :index }.visibility
      assert_includes graph.constants.map(&:name), 'Admin::Users::RolesController::TOKEN'
      refute_includes graph.constants.map(&:name), 'Users::RolesController::TOKEN'
      inheritance = graph.edges.find do |edge|
        edge.type == :inherits_from && edge.from_constant == 'Admin::Users::RolesController'
      end
      assert_equal 'Admin::BaseController', graph.resolve_edge_constant(inheritance)
      mixin = graph.edges.find do |edge|
        edge.type == :includes && edge.from_constant == 'Admin::Users::RolesController'
      end
      assert_equal 'Admin::Trackable', graph.resolve_edge_constant(mixin)
    end
  end

  def test_compact_class_paths_are_rebased_by_location
    with_project do |root|
      write "#{root}/app/controllers/roles_controllers.rb", <<~RUBY
        module Admin
          class Users::RolesController
            TOKEN = :admin
            def admin = TOKEN
          end
        end

        module Staff
          class Users::RolesController
            TOKEN = :staff
            def staff = TOKEN
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :controllers, in: 'app/controllers/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      admin = graph.constants_named('Admin::Users::RolesController').first
      staff = graph.constants_named('Staff::Users::RolesController').first

      assert_equal %i[admin], admin.instance_methods.to_a
      assert_equal %i[staff], staff.instance_methods.to_a
      assert graph.constants_named('Admin::Users::RolesController::TOKEN').one?
      assert graph.constants_named('Staff::Users::RolesController::TOKEN').one?
    end
  end

  def test_static_mixin_fallbacks_cover_top_level_calls_without_indexing_extend_self
    with_project do |root|
      write "#{root}/lib/extensions.rb", <<~RUBY
        module SerializationPatch
        end

        prepend SerializationPatch

        module Helpers
          extend self

          def answer = 42
        end
      RUBY

      definition = ArchSpec.define do
        component :extensions, in: 'lib/**/*.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      top_level_prepend = graph.edges.any? do |edge|
        edge.type == :prepends && edge.from_constant.nil? && edge.to == 'SerializationPatch'
      end
      assert top_level_prepend
      extend_self = graph.edges.find do |edge|
        edge.type == :extends && edge.from_constant == 'Helpers' && edge.to == 'Helpers'
      end
      assert_nil extend_self, extend_self&.inspect
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

  def test_component_exclusions_subtract_only_from_file_patterns
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/app/models/import_workflow.rb", "class ImportWorkflow; end\n"

      definition = ArchSpec.define do
        component :domain, in: 'app/models/**/*.rb', except: 'app/models/**/*_workflow.rb', constants: 'ImportWorkflow'
        component :workflows, in: 'app/models/**/*_workflow.rb'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal %w[ImportWorkflow User], graph.components.fetch(:domain).constants.to_a.sort
      assert_equal %w[ImportWorkflow], graph.components.fetch(:workflows).constants.to_a
      refute_includes graph.components.fetch(:domain).file_reasons.fetch("#{root}/app/models/import_workflow.rb"),
        'defined in matched file'
    end
  end

  def test_components_can_select_transitive_descendants
    with_project do |root|
      write "#{root}/app/models/application_record.rb", "class ApplicationRecord; end\n"
      write "#{root}/app/models/account.rb", "class Account < ApplicationRecord; end\n"
      write "#{root}/app/models/admin.rb", "class Admin < Account; end\n"
      write "#{root}/app/models/report.rb", "class Report; end\n"

      definition = ArchSpec.define do
        component :records, descendants_of: 'ApplicationRecord'
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal %w[Account Admin], graph.components.fetch(:records).constants.to_a.sort
      assert_equal ['descends from ApplicationRecord'],
        graph.component_assignment_reasons_for_constant('Admin').fetch(:records)
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
          Error = Class.new(StandardError)
          Fallback = Class.new(Error)
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
      assert_equal 'Billing::Error', fallback.superclass
      inheritance = graph.edges.find do |edge|
        edge.type == :inherits_from && edge.from_constant == 'Billing::Fallback'
      end
      assert_equal 'Error', inheritance.to
      assert_equal 'Billing::Error', graph.resolve_edge_constant(inheritance)
    end
  end

  def test_builds_graph_from_rubydex_with_syntax_overlay
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
end
