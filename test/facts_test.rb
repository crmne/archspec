# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class FactsTest < ArchSpecTest
  def test_facts_file_references_are_visible_to_dependency_rules
    with_project do |root|
      write_models(root)
      write "#{root}/archspec_facts/rails.yml", facts_yaml(references: [reference('User', 'Session')])

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      diagnostic = diagnostics.first
      assert_equal 'dependencies.forbid', diagnostic.rule
      assert_equal 'models must not depend on sessions', diagnostic.message
      assert_equal 'User references Session (from archspec_facts/rails.yml)', diagnostic.evidence
      assert_equal :from_facts_file, diagnostic.confidence
      assert_equal 3, diagnostic.location.line
    end
  end

  def test_without_a_facts_file_the_association_is_invisible
    with_project do |root|
      write_models(root)

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_generated_methods_count_as_the_owners_own_api
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def summary
            session
          end
        end
      RUBY
      write "#{root}/archspec_facts/rails.yml", facts_yaml(generated_methods: [{ 'owner' => 'User', 'names' => %w[session session=] }])

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :session, receiver: :none
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_unknown_entry_fields_are_refused_naming_the_file_and_entry
    with_project do |root|
      write_models(root)
      entry = reference('User', 'Session').merge('guess' => true)
      write "#{root}/archspec_facts/rails.yml", facts_yaml(references: [entry])

      error = assert_raises(ArchSpec::Error) { diagnostics_for(definition, root) }
      assert_match 'archspec_facts/rails.yml', error.message
      assert_match 'reference 1 has unknown field "guess"', error.message
    end
  end

  def test_unknown_format_versions_are_refused
    with_project do |root|
      write_models(root)
      write "#{root}/archspec_facts/rails.yml", facts_yaml.sub('format: 1', 'format: 2')

      error = assert_raises(ArchSpec::Error) { diagnostics_for(definition, root) }
      assert_match 'format 2 is not 1', error.message
    end
  end

  def test_unknown_top_level_keys_are_refused
    with_project do |root|
      write_models(root)
      write "#{root}/archspec_facts/rails.yml", "#{facts_yaml}routes: []\n"

      error = assert_raises(ArchSpec::Error) { diagnostics_for(definition, root) }
      assert_match 'unknown key "routes"', error.message
    end
  end

  def test_targets_the_parser_never_defined_stay_unresolved
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/archspec_facts/rails.yml", facts_yaml(references: [reference('User', 'Gem::Session')])

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.can_only_use
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      edge = graph.edges.find { |candidate| candidate.confidence == :from_facts_file }

      refute_nil edge
      assert_empty graph.target_components_for(edge)
      assert_empty ArchSpec::Evaluator.evaluate(definition, graph)
    end
  end

  def test_text_output_names_the_merged_files_or_the_absent_directory
    with_project do |root|
      write_models(root)
      write "#{root}/Archspec.rb", config

      output = StringIO.new
      Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: output, error: StringIO.new) }
      assert_match 'facts: none (archspec_facts/ absent)', output.string

      write "#{root}/archspec_facts/rails.yml", facts_yaml(references: [reference('User', 'Session')])
      output = StringIO.new
      Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: output, error: StringIO.new) }
      assert_match 'facts: archspec_facts/rails.yml (archspec-reflect 1.0.1, 1 entry)', output.string
      assert_match 'note: User references Session (from archspec_facts/rails.yml) (confidence: from_facts_file)',
                   output.string
    end
  end

  def test_json_output_lists_the_merged_files
    with_project do |root|
      write_models(root)
      write "#{root}/Archspec.rb", config
      write "#{root}/archspec_facts/rails.yml", facts_yaml(references: [reference('User', 'Session')])

      output = StringIO.new
      Dir.chdir(root) { ArchSpec::CLI.run(['check', '--format', 'json'], output: output, error: StringIO.new) }
      payload = JSON.parse(output.string)

      assert_equal [{ 'path' => 'archspec_facts/rails.yml', 'producer' => 'archspec-reflect',
                      'producer_version' => '1.0.1', 'commit' => nil, 'dirty' => false,
                      'entries' => 1, 'misses' => { 'polymorphic' => 2 } }], payload['facts_files']
      assert_equal 'from_facts_file', payload['violations'].first['confidence']
    end
  end

  def test_json_output_has_an_empty_list_when_the_directory_is_absent
    with_project do |root|
      write_models(root)
      write "#{root}/Archspec.rb", config

      output = StringIO.new
      Dir.chdir(root) { ArchSpec::CLI.run(['check', '--format', 'json'], output: output, error: StringIO.new) }

      assert_equal [], JSON.parse(output.string)['facts_files']
    end
  end

  def test_facts_directory_is_configurable
    with_project do |root|
      write_models(root)
      write "#{root}/config/facts/rails.yml", facts_yaml(references: [reference('User', 'Session')])

      definition = ArchSpec.define do
        facts 'config/facts'
        component :models, in: 'app/models/**/*.rb'
        component :sessions, in: 'app/models/session.rb'
        models.cannot_use :sessions
      end

      assert_equal 1, diagnostics_for(definition, root).size
    end
  end

  def test_explain_shows_facts_file_edges
    with_project do |root|
      write_models(root)
      write "#{root}/archspec_facts/rails.yml", facts_yaml(references: [reference('User', 'Session')])
      write "#{root}/Archspec.rb", config

      output = StringIO.new
      Dir.chdir(root) { ArchSpec::CLI.run(['explain', 'app/models/user.rb'], output: output, error: StringIO.new) }

      assert_match(/3:1 │ references Session/, output.string)
    end
  end

  private

  def write_models(root)
    write "#{root}/app/models/user.rb", <<~RUBY
      class User < ApplicationRecord
        has_many :posts
        belongs_to :session
      end
    RUBY
    write "#{root}/app/models/session.rb", "class Session < ApplicationRecord; end\n"
  end

  def definition
    ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      component :sessions, in: 'app/models/session.rb'
      models.cannot_use :sessions
    end
  end

  def config
    <<~RUBY
      component :models, in: 'app/models/**/*.rb'
      component :sessions, in: 'app/models/session.rb'
      models.cannot_use :sessions
    RUBY
  end

  def reference(owner, target)
    {
      'owner' => owner,
      'file' => 'app/models/user.rb',
      'line' => 3,
      'target' => target,
      'macro' => 'belongs_to',
      'name' => 'session'
    }
  end

  def facts_yaml(references: [], generated_methods: [])
    {
      'format' => 1,
      'producer' => 'archspec-reflect',
      'producer_version' => '1.0.1',
      'commit' => nil,
      'dirty' => false,
      'references' => references,
      'generated_methods' => generated_methods,
      'misses' => { 'polymorphic' => 2 }
    }.to_yaml
  end
end
