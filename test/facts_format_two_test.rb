# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'
require 'yaml'

class FactsFormatTwoTest < ArchSpecTest
  def test_an_ancestry_entry_makes_a_concern_see_its_includer
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  include Trackable\nend\n"
      write "#{root}/app/models/concerns/trackable.rb", "module Trackable\n  def track = User.count\nend\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(ancestry: [ancestry('User', 'includes', 'Trackable', 'app/models/user.rb')])

      definition = ArchSpec.define do
        component :concerns, in: 'app/models/concerns/**/*.rb'
        concerns.cannot_reference_includers
      end

      assert_equal ['concerns.independence'], diagnostics_for(definition, root).map(&:rule)
    end
  end

  def test_an_inherits_entry_is_a_dependency_edge_the_parser_never_saw
    with_project do |root|
      write "#{root}/app/models/user.rb", "User = Class.new\n"
      write "#{root}/app/models/base.rb", "class Base; end\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(ancestry: [ancestry('User', 'inherits', 'Base', 'app/models/user.rb')])

      definition = ArchSpec.define do
        component :users, in: 'app/models/user.rb'
        component :bases, in: 'app/models/base.rb'
        users.cannot_use :bases
      end

      diagnostic = diagnostics_for(definition, root).first
      assert_equal 'dependencies.forbid', diagnostic.rule
      assert_equal 'User inherits from Base (from archspec_facts/x.yml)', diagnostic.evidence
      assert_equal 'Base', ArchSpec::Analyzer.analyze(definition, root: root).constants_named('User').first.superclass
    end
  end

  def test_a_definition_entry_satisfies_must_implement
    with_project do |root|
      write "#{root}/app/commands/charge.rb", "class Charge\n  define_method(:call) { 1 }\nend\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(definitions: [definition_entry('Charge', 'call', 'instance', 'app/commands/charge.rb')])

      definition = ArchSpec.define do
        component :commands, in: 'app/commands/**/*.rb'
        commands.must_implement :call
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_a_class_scoped_definition_lands_on_the_class_side
    with_project do |root|
      write "#{root}/app/commands/charge.rb", "class Charge; end\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(definitions: [definition_entry('Charge', 'perform_later', 'class', 'app/commands/charge.rb')])

      definition = ArchSpec.define { component :commands, in: 'app/commands/**/*.rb' }
      charge = ArchSpec::Analyzer.analyze(definition, root: root).constants_named('Charge').first

      assert_includes charge.class_methods, :perform_later
      refute_includes charge.instance_methods, :perform_later
    end
  end

  def test_a_call_entry_is_a_typed_call_the_rule_sees
    with_project do |root|
      write "#{root}/app/services/report.rb", "class Report\n  def run(scope) = scope.destroy_all\nend\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(calls: [call('Report', 'app/services/report.rb', 2, 'destroy_all', 'User')])

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_call :destroy_all
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      typed = graph.edges.select { |edge| edge.type == :calls_named_method && edge.receiver_constant }

      assert_equal ['User'], typed.map(&:receiver_constant)
      assert_equal :constant, typed.first.receiver
      assert_equal 1, diagnostics_for(definition, root).count { |diagnostic| diagnostic.rule == 'methods.forbid' }
    end
  end

  def test_entries_the_parser_already_had_are_counted_not_merged
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User < Base\n  include Trackable\n  def save; end\nend\n"
      write "#{root}/app/models/base.rb", "class Base; end\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(
        ancestry: [ancestry('User', 'inherits', 'Base', 'app/models/user.rb'),
                   ancestry('User', 'includes', 'Trackable', 'app/models/user.rb')],
        definitions: [definition_entry('User', 'save', 'instance', 'app/models/user.rb')]
      )

      graph = ArchSpec::Analyzer.analyze(models_definition, root: root)

      assert_equal({ 'already_resolved' => 3 }, graph.facts_merges['archspec_facts/x.yml'])
      assert_equal 1, graph.edges.count { |edge| edge.type == :inherits_from }
      assert_equal 1, graph.constants_named('User').first.method_definitions.count { |m| m.name == :save }
    end
  end

  def test_a_call_entry_naming_a_receiver_the_parser_typed_differently_is_a_conflict
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  def build\n    UsersController.new\n  end\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(calls: [{ 'owner' => 'User', 'file' => 'app/models/user.rb',
                                                                 'line' => 3, 'method' => 'new', 'receiver' => 'Baz' }])

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal({ 'conflict' => 1 }, graph.census.facts_entries.fetch('archspec_facts/x.yml').fetch(:skipped))
    end
  end

  def test_an_ancestry_entry_contradicting_the_parser_is_a_conflict
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User < Base; end\n"
      write "#{root}/app/models/base.rb", "class Base; end\nclass Other; end\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(ancestry: [ancestry('User', 'inherits', 'Other', 'app/models/user.rb')])

      graph = ArchSpec::Analyzer.analyze(models_definition, root: root)

      assert_equal({ 'conflict' => 1 }, graph.facts_merges['archspec_facts/x.yml'])
      assert_equal 'Base', graph.constants_named('User').first.superclass
    end
  end

  def test_a_format_one_file_still_loads_with_the_new_lists_empty
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(references: [reference_entry('User', 'Session')]).sub('format: 2', 'format: 1')

      graph = ArchSpec::Analyzer.analyze(models_definition, root: root)

      assert_equal 1, graph.facts_files.size
      assert_equal({ references: 1, generated_methods: 0, ancestry: 0, definitions: 0, calls: 0 },
                   graph.facts_files.first.counts)
    end
  end

  def test_entry_fields_are_validated_by_name
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/archspec_facts/x.yml",
            facts_yaml(ancestry: [ancestry('User', 'inherits', 'Base', 'app/models/user.rb').merge('kind' => 'extends_from')])

      error = assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(models_definition, root: root) }
      assert_match 'ancestry entry 1 has kind "extends_from"', error.message

      write "#{root}/archspec_facts/x.yml",
            facts_yaml(definitions: [definition_entry('User', 'x', 'static', 'app/models/user.rb')])
      error = assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(models_definition, root: root) }
      assert_match 'definition 1 has scope "static"', error.message

      write "#{root}/archspec_facts/x.yml", facts_yaml(calls: [{ 'owner' => 'User', 'file' => 'app/models/user.rb', 'line' => 1 }])
      error = assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(models_definition, root: root) }
      assert_match 'call 1 is missing "method"', error.message
    end
  end

  def test_the_census_and_both_formatters_report_entries_per_type_per_producer
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User < Base; end\n"
      write "#{root}/app/models/base.rb", "class Base; end\n"
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"
      write "#{root}/archspec_facts/x.yml", facts_yaml(
        ancestry: [ancestry('User', 'inherits', 'Base', 'app/models/user.rb')],
        definitions: [definition_entry('User', 'save', 'instance', 'app/models/user.rb')]
      )

      text = StringIO.new
      Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: text, error: StringIO.new) }
      assert_match 'archspec_facts/x.yml (test 1, 2 entries: 1 ancestry, 1 definitions; skipped 1 already resolved)', text.string

      json = StringIO.new
      Dir.chdir(root) { ArchSpec::CLI.run(['check', '--format', 'json'], output: json, error: StringIO.new) }
      payload = JSON.parse(json.string)
      assert_equal({ 'already_resolved' => 1 }, payload['facts_files'].first['skipped'])
      assert_equal 1, payload['facts_files'].first['entries_by_type']['ancestry']
      assert_equal({ 'producer' => 'test', 'entries' => { 'references' => 0, 'generated_methods' => 0, 'ancestry' => 1,
                                                          'definitions' => 1, 'calls' => 0 },
                     'skipped' => { 'already_resolved' => 1 } },
                   payload['census']['facts_entries']['archspec_facts/x.yml'])
    end
  end

  def test_the_written_file_round_trips_every_list
    with_project do |root|
      path = "#{root}/archspec_facts/x.yml"
      FileUtils.mkdir_p(File.dirname(path))
      ArchSpec::Facts.write(
        path, producer: 'test', producer_version: '1', commit: nil, dirty: false, references: [], generated_methods: [],
        ancestry: [ArchSpec::FactsAncestry.new(owner: 'B', kind: 'includes', target: 'M', file: 'b.rb', line: 2, determination: 'x')],
        definitions: [ArchSpec::FactsDefinition.new(owner: 'B', name: 'run', scope: 'class', visibility: 'private', file: 'b.rb', line: 3, determination: nil)],
        calls: [ArchSpec::FactsCall.new(owner: 'B', file: 'b.rb', line: 4, method: 'go', receiver: 'C', determination: 'x')],
        misses: {}
      )

      file = ArchSpec::Facts.load_file(path, root: root)

      assert_equal 2, YAML.safe_load_file(path)['format']
      assert_equal [['B', 'includes', 'M', 'b.rb', 2, 'x']], file.ancestry.map { |e| [e.owner, e.kind, e.target, e.file, e.line, e.determination] }
      assert_equal [['B', 'run', 'class', 'private', 3]], file.definitions.map { |e| [e.owner, e.name, e.scope, e.visibility, e.line] }
      assert_equal [['B', 'go', 'C', 4]], file.calls.map { |e| [e.owner, e.method, e.receiver, e.line] }
    end
  end

  def test_the_static_association_producer_states_the_chain_it_walked
    with_project do |root|
      write "#{root}/app/models/application_record.rb", "class ApplicationRecord < ActiveRecord::Base\n  self.abstract_class = true\nend\n"
      write "#{root}/app/models/person.rb", "class Person < ApplicationRecord; end\n"
      write "#{root}/app/models/employee.rb", "class Employee < Person\n  belongs_to :person\nend\n"
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      facts = ArchSpec::Associations.facts_for(graph)

      assert_equal [['Employee', 'inherits', 'Person', 'app/models/employee.rb', 'index'],
                    ['Person', 'inherits', 'ApplicationRecord', 'app/models/person.rb', 'index']],
                   facts[:ancestry].map { |e| [e.owner, e.kind, e.target, e.file, e.determination] }
    end
  end

  def test_the_rubydex_producer_writes_the_three_lists_only_where_the_parser_had_nothing
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User < Base\n  include Trackable\n  def save; end\n  def run(s) = s.destroy_all\nend\n"
      write "#{root}/app/models/base.rb", "class Base; end\n"
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      facts = ArchSpec::Rubydex.facts_for(
        graph, [],
        ancestry: [ArchSpec::Rubydex::Ancestry.new(owner: 'User', kind: 'inherits', target: 'Base', file: 'app/models/user.rb', line: 1, in_workspace: true),
                   ArchSpec::Rubydex::Ancestry.new(owner: 'User', kind: 'includes', target: 'Trackable', file: 'app/models/user.rb', line: 2, in_workspace: false),
                   ArchSpec::Rubydex::Ancestry.new(owner: 'User', kind: 'extends', target: 'Forwardable', file: 'app/models/user.rb', line: 1, in_workspace: false)],
        definitions: [ArchSpec::Rubydex::Definition.new(owner: 'User', name: 'save', scope: 'instance', visibility: 'public', file: 'app/models/user.rb', line: 3),
                      ArchSpec::Rubydex::Definition.new(owner: 'User', name: 'touch', scope: 'instance', visibility: 'public', file: 'app/models/user.rb', line: 3)],
        calls: [ArchSpec::Rubydex::Call.new(file: 'app/models/user.rb', line: 4, method: 'destroy_all', receiver: 'Base', in_workspace: true)]
      )

      assert_equal [['User', 'extends', 'Forwardable', 'rubydex-gem']], facts[:ancestry].map { |e| [e.owner, e.kind, e.target, e.determination] }
      assert_equal [['User', 'touch', 'instance']], facts[:definitions].map { |e| [e.owner, e.name, e.scope] }
      assert_equal [['User', 4, 'destroy_all', 'Base', 'rubydex-workspace']], facts[:calls].map { |e| [e.owner, e.line, e.method, e.receiver, e.determination] }
      assert_equal({ 'ancestry_already_resolved' => 2, 'definition_already_resolved' => 1 }, facts[:misses])
    end
  end

  def test_the_real_gem_writes_format_two_for_archspec_itself
    skip 'set ARCHSPEC_RUBYDEX=1 to run the producer against the installed gem' unless ENV['ARCHSPEC_RUBYDEX']
    begin
      require 'rubydex'
    rescue LoadError
      skip 'the rubydex gem is not loadable by this Ruby'
    end

    root = File.expand_path('..', __dir__)
    definition, = ArchSpec::CLI.send(:load_definition, File.join(root, 'Archspec.rb'))
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    Dir.mktmpdir do |dir|
      facts = ArchSpec::Rubydex.run(graph, output: File.join(dir, 'rubydex.yml'), root: root)
      document = YAML.safe_load_file(File.join(dir, 'rubydex.yml'))

      assert_equal 2, document['format']
      assert document['calls'].all? { |entry| entry['receiver'].match?(/\A[A-Z]/) }
      assert_equal document['definitions'].sort_by { |e| [e['owner'], e['scope'], e['name']] }, document['definitions']
      warn "rubydex on archspec: #{facts.slice(:references, :ancestry, :definitions, :calls).transform_values(&:size)} misses #{facts[:misses]}"
    end
  end

  private

  def models_definition
    ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
  end

  def facts_yaml(references: [], ancestry: [], definitions: [], calls: [])
    {
      'format' => 2, 'producer' => 'test', 'producer_version' => '1',
      'references' => references, 'generated_methods' => [],
      'ancestry' => ancestry, 'definitions' => definitions, 'calls' => calls
    }.to_yaml
  end

  def reference_entry(owner, target)
    { 'owner' => owner, 'file' => 'app/models/user.rb', 'line' => 1, 'target' => target }
  end

  def ancestry(owner, kind, target, file)
    { 'owner' => owner, 'kind' => kind, 'target' => target, 'file' => file, 'line' => 1 }
  end

  def definition_entry(owner, name, scope, file)
    { 'owner' => owner, 'name' => name, 'scope' => scope, 'file' => file, 'line' => 1 }
  end

  def call(owner, file, line, method, receiver)
    { 'owner' => owner, 'file' => file, 'line' => line, 'method' => method, 'receiver' => receiver }
  end
end
