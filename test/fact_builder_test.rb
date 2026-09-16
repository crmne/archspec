# frozen_string_literal: true

require 'test_helper'

class FactBuilderTest < ArchSpecTest
  def test_in_memory_and_serialized_facts_have_the_same_rule_behavior
    with_project do |root|
      write "#{root}/lib/framework.rb", <<~RUBY
        raise 'analysis must not boot the framework'
        module Framework
          class Customer; end
          module Early
            def process = nil
          end
          module Late
            def process(value, currency:) = value
          end
          module ClassAPI
            def find(id) = id
          end
          register :customer
          session
          params
        end
      RUBY
      write "#{root}/lib/record.rb", <<~RUBY
        class Record
          configure_api
          def self.find = nil
        end
      RUBY
      definition = ArchSpec.define do
        component :records, constants: 'Record'
        component :framework, namespace: 'Framework'
        records.must_implement :process, arity: 1, keywords: :currency
        records.must_implement :find, scope: :class, arity: 1
        records.must_implement :customer, arity: 0
        framework.cannot_call :session, :params, receiver: :none
        facts
      end
      memory = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      builder = builder_for(memory)
      owner = memory.constants_named('Record').first
      framework = memory.constants_named('Framework').first
      site = call_named(memory, 'register').location
      # Populate caches before importing facts to exercise invalidation.
      assert_empty memory.effective_instance_methods('Record').first
      builder.reference(source: owner, target: 'Framework::Customer', location: site)
      builder.methods(owner: owner, names: %i[customer], location: site, signatures: [{ required: 0 }])
      builder.methods(owner: owner, names: %i[internal], location: site, visibility: :private,
        signatures: [{ required: 1, optional: 1, keywords: ['currency'], optional_keywords: ['locale'],
                       rest: true, keyword_rest: true, block: true }])
      builder.methods(owner: owner, names: %i[session], location: site, scope: :class, alias_target: :customer)
      builder.mixin(owner: owner, target: 'Framework::Early', kind: :include, location: site)
      builder.mixin(owner: owner, target: 'Framework::Late', kind: :include, location: site)
      builder.mixin(owner: owner, target: 'Framework::ClassAPI', kind: :singleton_prepend, location: site)
      builder.expose_methods(source: memory.constants_named('Framework::ClassAPI').first, owner: framework, scope: :class)
      builder.bind_receiver(edge: call_named(memory, 'session'), receiver: 'Record', scope: :class)
      builder.gap(source: owner, location: site, message: 'unresolved runtime target')
      document = builder.to_document
      assert_equal 2, document['version']
      assert_equal 'lib/record.rb', document['references'].first['source_path']
      assert_equal 'lib/framework.rb', document['references'].first['path']
      builder.apply
      ArchSpec::Facts.write("#{root}/archspec_facts/framework.yml", document)
      imported = ArchSpec::Analyzer.analyze(definition, root: root)

      [memory, imported].each do |graph|
        diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
        assert_equal ['methods.forbid'], diagnostics.map(&:rule)
        assert_match(/params/, diagnostics.first.message)
        methods, = graph.effective_method_definitions('Record', :instance)
        assert_equal ['Framework::Late'], methods.select { |method| method.name == :process }.map(&:owner)
        internal = methods.find { |method| method.name == :internal }
        assert_equal :private, internal.visibility
        assert internal.signatures.first.accepts_arity?(8)
        assert internal.signatures.first.accepts_keywords?(%i[currency extra])
        assert_equal :customer, graph.resolve_method_alias('Record', :session, :class)
        exposed = graph.method_definitions.find { |method| method.name == :find && method.owner == 'Framework' }
        assert_equal :class, exposed.scope
        edge = call_named(graph, 'session')
        assert_equal ['Framework', 'Record', :class, :customer],
          [edge.from_constant, edge.resolved_receiver, edge.receiver_scope, edge.resolved_method]
        assert graph.edges.any? { |edge| edge.type == :dynamic_feature && edge.to == 'unresolved runtime target' }
      end
    end
  end

  def test_receiver_facts_across_files_preserve_all_consumers_and_resolve_after_all_methods
    with_project do |root|
      write "#{root}/lib/records.rb", "module Shared\n  dispatch\nend\nclass First; end\nclass Second; end\n"
      graph = analyze(root)
      edge = call_named(graph, 'dispatch')
      %w[First Second].each_with_index do |name, index|
        builder = builder_for(graph)
        builder.bind_receiver(edge: edge, receiver: name, scope: :instance)
        ArchSpec::Facts.write("#{root}/archspec_facts/#{index}.yml", builder.to_document)
      end
      builder = builder_for(graph)
      builder.methods(owner: graph.constants_named('Second').first, names: ['dispatch'], location: edge.location,
        alias_target: :perform)
      ArchSpec::Facts.write("#{root}/archspec_facts/z_methods.yml", builder.to_document)
      ArchSpec::Facts.load_into(graph, 'archspec_facts')
      calls = graph.edges.select { |candidate| candidate.type == :calls_named_method && candidate.to == 'dispatch' }
      assert_equal %w[First Second], calls.map(&:resolved_receiver)
      assert_equal [nil, :perform], calls.map(&:resolved_method)
      assert_equal ['Shared'], calls.map(&:from_constant).uniq
      assert_equal [edge.location], calls.map(&:location).uniq
    end
  end

  def test_installed_method_metadata_and_precedence_survive_serialization
    with_project do |root|
      write "#{root}/lib/records.rb", <<~RUBY
        module Provider
          private
          def generated(value, locale:) = value
        end
        class Earlier
          def generated = nil
          install_api
        end
        class Later
          install_api
          def generated = nil
        end
      RUBY
      graph = analyze(root)
      method = graph.constants_named('Provider').first.method_definitions.first
      builder = builder_for(graph)
      %w[Earlier Later].each do |name|
        owner = graph.constants_named(name).first
        origin = graph.edges.find { |edge| edge.from_constant == name && edge.to == 'install_api' }.location
        builder.method_definition(owner: owner, definition: method, installation: origin)
      end
      ArchSpec::Facts.write("#{root}/archspec_facts/framework.yml", builder.to_document)
      ArchSpec::Facts.load_into(graph, 'archspec_facts')
      earlier = graph.effective_method_definitions('Earlier', :instance).first.find { |entry| entry.name == :generated }
      later = graph.effective_method_definitions('Later', :instance).first.find { |entry| entry.name == :generated }
      assert_equal :private, earlier.visibility
      assert_equal method.location, earlier.location
      assert_equal method.signatures, earlier.signatures
      assert_equal :public, later.visibility
      assert_equal [0], later.signatures.map(&:required)
    end
  end

  def test_all_documents_are_validated_before_any_facts_are_applied
    with_project do |root|
      write "#{root}/lib/record.rb", "class Record; end\n"
      graph = analyze(root)
      owner = graph.constants_named('Record').first
      builder = builder_for(graph)
      builder.methods(owner: owner, names: ['generated'], location: owner.location)
      good = builder.to_document
      ArchSpec::Facts.write("#{root}/archspec_facts/a.yml", good)
      ArchSpec::Facts.write("#{root}/archspec_facts/z.yml", good.merge('mixins' => [{ 'kind' => 'unknown' }]))
      assert_raises(ArchSpec::Error) { ArchSpec::Facts.load_into(graph, 'archspec_facts') }
      refute_includes graph.effective_instance_methods('Record').first, :generated
    end
  end

  def test_invalid_rich_facts_are_rejected_without_partial_application
    with_project do |root|
      write "#{root}/lib/record.rb", "class Record\n  custom_macro\nend\n"
      graph = analyze(root)
      owner = graph.constants_named('Record').first
      builder = builder_for(graph)
      builder.methods(owner: owner, names: ['generated'], location: owner.location)
      good = builder.to_document
      method = good['methods'].first
      common = { 'path' => 'lib/record.rb', 'line' => 2 }
      invalid = [
        ['methods', method.merge('visibility' => 'secret')],
        ['methods', method.merge('signatures' => [{ 'required' => -1 }])],
        ['methods', method.merge('signatures' => [{ 'rest' => 'yes' }])],
        ['methods', method.merge('signatures' => [{ 'keywords' => [1] }])],
        ['methods', method.merge('signatures' => [{ 'unknown' => 1 }])],
        ['methods', method.merge('signatures' => [{ 'keywords' => ['key'], 'optional_keywords' => ['key'] }])],
        ['methods', method.merge('alias_target' => 1)],
        ['methods', method.merge('alias_target' => false)],
        ['methods', method.merge('mode' => 'replace_everything')],
        ['methods', method.merge('mode' => 'define')],
        ['methods', method.merge('installation' => false)],
        ['methods', method.merge('mode' => 'define', 'installation' => common.merge('path' => '../outside.rb'))],
        ['mixins', common.merge('owner' => 'Record', 'target' => 'API', 'kind' => 'unknown')],
        ['mixins', common.merge('owner' => 'Record', 'target' => nil, 'kind' => 'include')],
        ['receivers', common.merge('source' => 'Record', 'name' => 'missing', 'receiver' => 'Record', 'scope' => 'class')],
        ['exposures', common.merge('source' => 'Record', 'owner' => 'Record', 'scope' => 'class')]
      ]
      invalid.each do |key, entry|
        ArchSpec::Facts.write("#{root}/archspec_facts/framework.yml", good.merge(key => [entry]))
        assert_raises(ArchSpec::Error, entry.inspect) { ArchSpec::Facts.load_into(graph, 'archspec_facts') }
        refute_includes graph.effective_instance_methods('Record').first, :generated
      end
    end
  end

  def test_version_one_does_not_silently_accept_version_two_semantics
    with_project do |root|
      write "#{root}/lib/record.rb", "class Record; end\n"
      graph = analyze(root)
      owner = graph.constants_named('Record').first
      builder = builder_for(graph)
      builder.methods(owner: owner, names: ['generated'], location: owner.location)
      document = builder.to_document.merge('version' => 1)
      ArchSpec::Facts.write("#{root}/archspec_facts/framework.yml", document)
      assert_raises(ArchSpec::Error) { ArchSpec::Facts.load_into(graph, 'archspec_facts') }
      %w[mixins receivers exposures].each { |key| document.delete(key) }
      ArchSpec::Facts.write("#{root}/archspec_facts/framework.yml", document)
      assert_raises(ArchSpec::Error) { ArchSpec::Facts.load_into(graph, 'archspec_facts') }
    end
  end

  def test_conflicting_exposures_are_rejected_before_application
    with_project do |root|
      write "#{root}/lib/api.rb", "module API; def fetch = nil; end\nclass First; end\nclass Second; end\n"
      graph = analyze(root)
      %w[First Second].each do |name|
        owner = graph.constants_named(name).first
        builder = builder_for(graph)
        builder.methods(owner: owner, names: ['generated'], location: owner.location)
        builder.expose_methods(source: graph.constants_named('API').first, owner: owner, scope: :class)
        ArchSpec::Facts.write("#{root}/archspec_facts/#{name}.yml", builder.to_document)
      end
      error = assert_raises(ArchSpec::Error) { ArchSpec::Facts.load_into(graph, 'archspec_facts') }
      assert_match(/conflicting method exposure/, error.message)
      refute_includes graph.effective_instance_methods('First').first, :generated
    end
  end

  def test_builder_validation_preserves_previous_snapshot_on_failure
    with_project do |root|
      write "#{root}/lib/record.rb", "class Record; end\n"
      graph = analyze(root)
      path = "#{root}/archspec_facts/framework.yml"
      builder = builder_for(graph)
      ArchSpec::Facts.write(path, builder.to_document)
      previous = File.read(path)
      owner = graph.constants_named('Record').first
      builder.methods(owner: owner, names: ['generated'], location: owner.location, visibility: :unknown)
      assert_raises(ArchSpec::Error) { ArchSpec::Facts.write(path, builder.to_document) }
      assert_equal previous, File.read(path)
      assert_raises(ArchSpec::Error) { builder.apply }
      refute_includes graph.effective_instance_methods('Record').first, :generated
    end
  end

  def test_builder_rejects_non_string_alias_target_values
    with_project do |root|
      write "#{root}/lib/record.rb", "class Record; end\n"
      graph = analyze(root)
      owner = graph.constants_named('Record').first
      builder = builder_for(graph)
      error = assert_raises(ArchSpec::Error) do
        builder.methods(owner: owner, names: ['generated'], location: owner.location, alias_target: false)
      end
      assert_match(/alias target must be a String or Symbol/, error.message)
    end
  end

  private

  def analyze(root)
    definition = ArchSpec.define { component :library, in: 'lib/**/*.rb' }
    ArchSpec::Analyzer.analyze(definition, root: root)
  end

  def builder_for(graph)
    ArchSpec::Facts::Builder.new(graph, producer: 'custom_framework')
  end

  def call_named(graph, name)
    graph.edges.find { |edge| edge.type == :calls_named_method && edge.to == name }
  end
end
