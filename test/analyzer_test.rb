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
      write "#{root}/app/models/spot.rb", <<~RUBY
        class Spot < Struct.new(:x, :y)
          def locate
            self.class::ORIGIN
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      assert_empty diagnostics_for(definition, root)
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

  def test_tracks_method_visibility_across_declaration_forms
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def pub; end
          private def inline; end
          def after_inline; end
          private
          def bare_private; end
          public
          def repub; end
          private :repub
          private
          attr_reader :priv_attr
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
      assert_equal :private, visibility[[:bare_private, :instance]]
      assert_equal :private, visibility[[:repub, :instance]]
      assert_equal :private, visibility[[:priv_attr, :instance]]
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
end
