# frozen_string_literal: true

require 'test_helper'
require 'active_support/concern'

class ConcernSemanticsTest < ArchSpecTest
  def test_callbacks_belong_to_consumers_and_class_methods_use_the_class_api
    with_project do |root|
      write "#{root}/app/models/concerns/trackable.rb", <<~RUBY
        module Trackable
          extend ActiveSupport::Concern
          TRACKED_AT = :tracked_at
          module Tracking
            def track! = touch(TRACKED_AT)
          end
          included do
            include Tracking
          end
          class_methods do
            def tracked_since(time, actor:) = where(time, actor)
          end
        end
      RUBY
      write "#{root}/app/models/document.rb", "class Document; include Trackable; end\n"
      definition = ArchSpec.define do
        component :models, in: 'app/models/*.rb'
        component :concerns, in: 'app/models/concerns/**/*.rb'
        models.must_implement :track!
        models.must_implement :tracked_since, scope: :class, arity: 1, keywords: :actor
        concerns.cannot_reference_includers
        concerns.method_names(scope: :instance).matching(/tracked_since/).forbidden
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      assert_empty ArchSpec::Evaluator.evaluate(definition, graph)
      refute_includes graph.ancestor_names('Trackable').first, 'Trackable::Tracking'
      assert_includes graph.ancestor_names('Document').first, 'Trackable::Tracking'
      refute_includes graph.effective_class_methods('Trackable').first, :tracked_since
      assert_includes graph.effective_class_methods('Document').first, :tracked_since
      definition = graph.method_definitions_for_component(:concerns).find { |method| method.name == :tracked_since }
      assert_equal :class, definition.scope
      assert_equal 11, definition.location.line
      assert_equal 'Trackable', definition.owner
    end
  end

  def test_nested_class_methods_and_concern_dependencies_reach_the_final_consumer
    with_project do |root|
      write "#{root}/lib/concerns.rb", <<~RUBY
        module BaseConcern
          extend ActiveSupport::Concern
          module ClassMethods
            def find_record(id) = id
          end
          included do
            def ready? = true
            def self.enabled? = true
          end
        end
        module OuterConcern
          extend ActiveSupport::Concern
          include BaseConcern
        end
        class Record
          include OuterConcern
        end
        class ExplicitConsumer
          extend BaseConcern::ClassMethods
        end
      RUBY
      graph = analyze_library(root)
      assert_includes graph.effective_instance_methods('Record').first, :ready?
      assert_includes graph.effective_class_methods('Record').first, :enabled?
      assert_includes graph.effective_class_methods('Record').first, :find_record
      assert_includes graph.effective_class_methods('ExplicitConsumer').first, :find_record
      refute_includes graph.ancestor_names('OuterConcern').first, 'BaseConcern'
      refute_includes graph.effective_instance_methods('BaseConcern').first, :ready?
      refute_includes graph.effective_instance_methods('OuterConcern').first, :ready?
    end
  end

  def test_prepend_runs_only_the_matching_callback_and_prepends_class_methods
    with_project do |root|
      write "#{root}/lib/concerns.rb", <<~RUBY
        module Audited
          extend ActiveSupport::Concern
          module InstanceMethods
            def audit = true
          end
          prepended do
            include InstanceMethods
          end
          included do
            def included_only = true
          end
          class_methods do
            def find(id) = id
          end
        end
        class Record
          def self.find = nil
          prepend Audited
        end
      RUBY
      graph = analyze_library(root)
      methods, = graph.effective_instance_methods('Record')
      assert_includes methods, :audit
      refute_includes methods, :included_only
      methods, = graph.effective_method_definitions('Record', :class)
      assert_equal ['Audited::ClassMethods'], methods.select { |method| method.name == :find }.map(&:owner)
      refute_includes graph.ancestor_names('Audited').first, 'Audited::InstanceMethods'
    end
  end

  def test_ordinary_modules_and_direct_includes_keep_their_ruby_semantics
    with_project do |root|
      write "#{root}/lib/modules.rb", <<~RUBY
        module Ordinary
          class_methods do
            def ordinary = true
          end
        end
        module Greetable
          extend ActiveSupport::Concern
          GREETING = 'hello'
          module Resolution
            def greet = GREETING
          end
          include Resolution
        end
        class Record
          include Ordinary
        end
      RUBY
      graph = analyze_library(root)
      assert_includes graph.effective_instance_methods('Record').first, :ordinary
      refute_includes graph.effective_class_methods('Record').first, :ordinary
      assert_includes graph.ancestor_names('Greetable').first, 'Greetable::Resolution'
      definition = ArchSpec.define do
        component(:library, in: 'lib/**/*.rb').cannot_reference_includers
      end
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
      assert_equal ['concerns.independence'], diagnostics.map(&:rule)
      assert_match(/Greetable::Resolution must not reference its includer Greetable/, diagnostics.first.message)
    end
  end

  def test_conditional_callback_mixins_do_not_become_certain_ancestry
    with_project do |root|
      write "#{root}/lib/conditional.rb", <<~RUBY
        module Conditional
          extend ActiveSupport::Concern
          module Optional
            def optional = true
          end
          included do
            if ENV['OPTIONAL']
              include Optional
              def conditional = true
            end
          end
        end
        class Record
          include Conditional
        end
      RUBY
      graph = analyze_library(root)
      refute_includes graph.ancestor_names('Conditional').first, 'Conditional::Optional'
      refute_includes graph.ancestor_names('Record').first, 'Conditional::Optional'
      refute_includes graph.effective_instance_methods('Record').first, :conditional
      assert graph.edges.any? { |edge| edge.type == :dynamic_feature && edge.to == 'conditional included callback' }
    end
  end

  def test_blocks_after_a_conditional_callback_keep_their_own_edges
    with_project do |root|
      write "#{root}/lib/mixed.rb", <<~RUBY
        module Mixed
          extend ActiveSupport::Concern
          module Certain
            def certain = true
          end
          module Optional
            def optional = true
          end
          included do
            include Certain
            if ENV['OPTIONAL']
              include Optional
            end
          end
          class_methods do
            def build = Factory
            def build_all = build
          end
          def label = Label
        end
        class Record
          include Mixed::Certain
          include Mixed
        end
      RUBY
      definition = ArchSpec.define do
        component :library, in: 'lib/**/*.rb'
        library.cannot_call :build, receiver: :none
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      assert_empty ArchSpec::Evaluator.evaluate(definition, graph)
      assert_empty graph.edges.select { |edge| edge.from_constant == 'Mixed' && edge.type == :includes }
      assert_equal 1, graph.edges.count { |edge| edge.type == :dynamic_feature && edge.from_constant == 'Mixed' }
      assert_includes graph.ancestor_names('Record').first, 'Mixed::Certain'
      refute_includes graph.ancestor_names('Record').first, 'Mixed::Optional'
      record_includes = graph.edges.select { |edge| edge.from_constant == 'Record' && edge.type == :includes }
      assert_equal %w[Mixed Mixed::Certain], record_includes.map { |edge| graph.resolve_edge_constant(edge) }.sort
      assert_equal ['Mixed::ClassMethods'], graph.edges.select { |edge| edge.to == 'Factory' }.map(&:from_constant)
      assert_equal ['Mixed'], graph.edges.select { |edge| edge.to == 'Label' }.map(&:from_constant)
      call = graph.edges.find { |edge| edge.type == :calls_named_method && edge.to == 'build' }
      assert_equal ['Mixed::ClassMethods', 'Mixed::ClassMethods'], [call.from_constant, call.resolved_receiver]
      assert_includes graph.effective_class_methods('Record').first, :build
    end
  end

  def test_method_precedence_matches_active_support
    with_project do |root|
      path = "#{root}/lib/precedence.rb"
      write path, <<~RUBY
        module BaseConcern
          extend ActiveSupport::Concern
          def inherited_name(base) = base
        end
        module Feature
          extend ActiveSupport::Concern
          include BaseConcern
          def inherited_name = :feature
          included do
            def callback_name(callback) = callback
          end
        end
        module Later
          def inherited_name(later, argument) = later
        end
        class Record
          include Feature
          include Later
          def callback_name = :own
        end
      RUBY
      runtime = Module.new
      capture_io { runtime.module_eval(File.read(path), path) }
      record = runtime.const_get(:Record)
      graph = analyze_library(root)
      methods, = graph.effective_method_definitions('Record', :instance)
      %i[inherited_name callback_name].each do |name|
        actual = record.instance_method(name).arity
        definitions = methods.select { |method| method.name == name }
        assert_equal [actual], definitions.flat_map { |method| method.signatures.map(&:required) }
      end
    end
  end

  def test_transitive_concern_references_to_consumers_remain_violations
    with_project do |root|
      write "#{root}/lib/concerns.rb", <<~RUBY
        module Shared
          extend ActiveSupport::Concern
          def record_class = Record
        end
        module Feature
          extend ActiveSupport::Concern
          include Shared
        end
        class Record
          include Feature
        end
      RUBY
      definition = ArchSpec.define do
        component(:library, in: 'lib/**/*.rb').cannot_reference_includers
      end
      diagnostics = diagnostics_for(definition, root)
      assert_equal ['concerns.independence'], diagnostics.map(&:rule)
      assert_equal 'Shared must not reference its includer Record', diagnostics.first.message
      assert_equal 3, diagnostics.first.location.line
    end
  end

  def test_a_method_named_extend_does_not_activate_concern_semantics
    with_project do |root|
      write "#{root}/lib/ordinary.rb", <<~RUBY
        module Ordinary
          def setup
            extend ActiveSupport::Concern
          end
          class_methods do
            def ordinary = true
          end
        end
      RUBY
      graph = analyze_library(root)
      assert_includes graph.effective_instance_methods('Ordinary').first, :ordinary
      assert_empty graph.constants_named('Ordinary::ClassMethods')
    end
  end

  def test_callback_calls_resolve_against_the_consumer_api
    with_project do |root|
      write "#{root}/lib/owned.rb", <<~RUBY
        module Owned
          extend ActiveSupport::Concern
          included do
            def session = :own
            def local = session
            def forbidden = params
          end
        end
        class Record
          include Owned
        end
      RUBY
      definition = ArchSpec.define do
        component :concerns, constants: 'Owned'
        component :library, in: 'lib/**/*.rb'
        concerns.cannot_call :session, :params, receiver: :none
      end
      diagnostics = diagnostics_for(definition, root)
      assert_equal ['concerns must not call #params'], diagnostics.map(&:message)
      assert_equal 6, diagnostics.first.location.line
    end
  end

  private


  def analyze_library(root)
    definition = ArchSpec.define { component :library, in: 'lib/**/*.rb' }
    ArchSpec::Analyzer.analyze(definition, root: root)
  end
end
