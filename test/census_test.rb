# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'

class CensusTest < ArchSpecTest
  def test_a_fully_read_project_counts_nothing_unseen
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"

      census = ArchSpec::Analyzer.analyze(models_definition, root: root).census

      assert_equal [], census.clauses
      assert_equal 0, census.unresolved_references
      assert_nil census.producers
    end
  end

  def test_unresolved_constant_references_are_counted_with_their_names
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User < SomeGem::Base\n  Account\nend\n"
      write "#{root}/app/models/account.rb", "class Account; end\n"

      census = ArchSpec::Analyzer.analyze(models_definition, root: root).census

      assert_equal 1, census.resolved_references
      assert_equal 1, census.unresolved_references
      assert_equal ['SomeGem::Base'], census.unresolved_names
      assert_equal ['1 unresolved constant reference'], census.clauses
    end
  end

  def test_dynamic_features_are_counted_by_message_with_their_carriers
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def read(name)
            send(name)
          end

          def method_missing(name, *)
            super
          end
        end
      RUBY

      census = ArchSpec::Analyzer.analyze(models_definition, root: root).census

      assert_equal %w[method_missing send], census.dynamic_features.keys
      assert_equal ['User (app/models/user.rb:3)'], census.dynamic_features['send']
      assert_equal 2, census.dynamic_feature_count
    end
  end

  def test_calls_on_untyped_receivers_are_counted
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  def run(other) = other.go\nend\n"

      census = ArchSpec::Analyzer.analyze(models_definition, root: root).census

      assert_equal 1, census.other_receiver_calls
      assert_equal ['1 call with an untyped receiver'], census.clauses
    end
  end

  def test_ignored_files_and_parse_errors_are_counted
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/app/models/broken.rb", "class Broken\n"
      write "#{root}/app/models/generated.rb", "class Generated; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        ignore 'app/models/generated.rb'
      end
      census = ArchSpec::Analyzer.analyze(definition, root: root).census

      assert_equal 1, census.ignored_files
      assert_equal 1, census.parse_error_files
      assert_equal ['1 ignored file', '1 file with parse errors'], census.clauses
    end
  end

  def test_only_files_the_source_globs_would_have_read_count_as_ignored
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/vendor/gem/lib/thing.rb", "class Thing; end\n"
      write "#{root}/vendor/gem/README.md", "not ruby\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end
      census = ArchSpec::Analyzer.analyze(definition, root: root).census

      assert_equal 0, census.ignored_files
    end
  end

  def test_a_diagnostic_outside_any_constant_is_never_doubted
    with_project do |root|
      write "#{root}/app/models/user.rb", "send(:define_method, :x) { }\nUsersController\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end
      diagnostics = diagnostics_for(definition, root)

      assert_equal [:high], diagnostics.map(&:confidence)
    end
  end

  def test_edges_are_counted_per_producer_when_facts_are_present
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  Account\nend\n"
      write "#{root}/app/models/account.rb", "class Account; end\n"
      write "#{root}/archspec_facts/rails.yml", <<~YAML
        format: 1
        producer: test
        producer_version: "1"
        references:
          - owner: User
            file: app/models/user.rb
            line: 1
            target: Account
        generated_methods: []
      YAML

      census = ArchSpec::Analyzer.analyze(models_definition, root: root).census

      assert_equal({ 'parser' => 1, 'test' => 1 }, census.producers)
    end
  end

  def test_a_diagnostic_inside_a_constant_using_a_dynamic_feature_is_doubted
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def lookup(name)
            send(name)
          end

          def peek
            UsersController
          end
        end

        class Account
          def peek
            UsersController
          end
        end
      RUBY
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      diagnostics = diagnostics_for(forbid_definition, root)

      by_evidence = diagnostics.to_h { |diagnostic| [diagnostic.evidence, diagnostic] }
      doubted = by_evidence.fetch('User references UsersController')
      assert_equal :medium, doubted.confidence
      assert_equal 'send at line 3', doubted.caveat
      assert_equal :high, by_evidence.fetch('Account references UsersController').confidence
    end
  end

  def test_a_doubted_diagnostic_keeps_its_fingerprint_and_prints_the_caveat
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  send(:x)\n  UsersController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      graph = ArchSpec::Analyzer.analyze(forbid_definition, root: root)
      diagnostic = ArchSpec::Evaluator.evaluate(forbid_definition, graph).first
      plain = ArchSpec::Diagnostic.new(rule: diagnostic.rule, message: diagnostic.message,
                                       location: diagnostic.location, evidence: diagnostic.evidence)

      assert_equal plain.fingerprint(root: root), diagnostic.fingerprint(root: root)

      output = StringIO.new
      ArchSpec::Formatters::Text.print(output, graph: graph, diagnostics: [diagnostic])
      assert_match(/note: User references UsersController \(confidence: medium, send at line 2\)/, output.string)
    end
  end

  def test_unused_suppressions_and_stale_todo_entries_are_counted_and_hidden_by_default
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          # archspec:disable-next-line dependencies.forbid
          name
        end
      RUBY
      write "#{root}/archspec_todo.yml", <<~YAML
        violations:
          - id: deadbeefdeadbeefdeadbeef
            rule: dependencies.forbid
            path: app/models/gone.rb
            line: 1
            message: models must not depend on controllers
      YAML

      graph = ArchSpec::Analyzer.analyze(forbid_definition, root: root)
      todo = ArchSpec::Todo.load("#{root}/archspec_todo.yml", root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(forbid_definition, graph, todo: todo)

      assert_equal [], diagnostics
      assert_equal 1, graph.census.unused_suppressions
      assert_equal 1, graph.census.stale_todo_entries
      assert_equal ['1 unused suppression', '1 stale todo entry'], graph.census.clauses
    end
  end

  def test_housekeeping_reports_them_as_diagnostics_only_when_asked
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          # archspec:disable-next-line dependencies.forbid
          name
        end
      RUBY
      write "#{root}/archspec_todo.yml", <<~YAML
        violations:
          - id: deadbeefdeadbeefdeadbeef
            rule: dependencies.forbid
            path: app/models/gone.rb
            line: 1
            message: models must not depend on controllers
      YAML

      graph = ArchSpec::Analyzer.analyze(forbid_definition, root: root)
      todo = ArchSpec::Todo.load("#{root}/archspec_todo.yml", root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(forbid_definition, graph, todo: todo, housekeeping: true)

      assert_equal %w[housekeeping.stale_todo housekeeping.unused_suppression], diagnostics.map(&:rule).sort
      unused = diagnostics.find { |diagnostic| diagnostic.rule == 'housekeeping.unused_suppression' }
      assert_equal "#{root}/app/models/user.rb", unused.location.path
      assert_equal 3, unused.location.line
      assert_equal 'suppression of dependencies.forbid matched no diagnostic', unused.message
      stale = diagnostics.find { |diagnostic| diagnostic.rule == 'housekeeping.stale_todo' }
      assert_equal "#{root}/archspec_todo.yml", stale.location.path
      assert_match(/deadbeefdeadbeefdeadbeef dependencies\.forbid app\/models\/gone\.rb/, stale.evidence)
    end
  end

  def test_the_text_summary_names_what_it_could_not_see_on_passing_and_failing_runs
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User < SomeGem::Base\n  UsersController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      failing = StringIO.new
      graph = ArchSpec::Analyzer.analyze(forbid_definition, root: root)
      ArchSpec::Formatters::Text.print(failing, graph: graph,
                                                diagnostics: ArchSpec::Evaluator.evaluate(forbid_definition, graph))
      assert_match(/^could not see: 1 unresolved constant reference$/, failing.string)

      passing = StringIO.new
      graph = ArchSpec::Analyzer.analyze(models_definition, root: root)
      ArchSpec::Formatters::Text.print(passing, graph: graph,
                                                diagnostics: ArchSpec::Evaluator.evaluate(models_definition, graph))
      assert_match(/^ArchSpec passed: .*\nfacts: none .*\ncould not see: 1 unresolved constant reference$/, passing.string)
    end
  end

  def test_a_blinded_run_and_a_full_run_print_different_summaries
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"

      full = summary_for(models_definition, root)
      blinded = summary_for(ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        ignore 'app/**/*.rb'
      end, root)

      assert_match(/could not see: nothing/, full)
      assert_match(/could not see: 1 ignored file/, blinded)
    end
  end

  def test_json_carries_the_census
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: \"app/models/**/*.rb\"\n"
      write "#{root}/app/models/user.rb", "class User < SomeGem::Base\n  send(:x)\nend\n"

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check', '--format', 'json'], output: output, error: StringIO.new) }

      assert_equal 0, status
      census = JSON.parse(output.string).fetch('census')
      assert_equal({ 'resolved' => 0, 'through_ancestry' => 0, 'unresolved' => 1, 'unresolved_names' => ['SomeGem::Base'],
                     'refused' => { 'ancestor_unresolved' => 0, 'ambiguous' => 0, 'names' => [] } }, census['references'])
      assert_equal({ 'count' => 1, 'carriers' => ['User (app/models/user.rb:2)'] }, census['dynamic_features']['send'])
      assert_equal 0, census['other_receiver_calls']
      assert_nil census['producers']
      assert_equal 0, census['stale_todo_entries']
    end
  end

  def test_housekeeping_flag_fails_the_run_and_is_rejected_with_update_todo
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        todo "archspec_todo.yml"
      RUBY
      write "#{root}/app/models/user.rb", "# archspec:disable-next-line components.empty\nclass User; end\n"

      quiet = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: StringIO.new, error: StringIO.new) }
      assert_equal 0, quiet

      output = StringIO.new
      loud = Dir.chdir(root) { ArchSpec::CLI.run(['check', '--housekeeping'], output: output, error: StringIO.new) }
      assert_equal 1, loud
      assert_match(/\[housekeeping\.unused_suppression\]/, output.string)

      error = StringIO.new
      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['check', '--update-todo', '--housekeeping'], output: StringIO.new, error: error)
      end
      assert_equal 1, status
      assert_match(/cannot combine --update-todo with --housekeeping/, error.string)
    end
  end

  private

  def models_definition
    ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
  end

  def forbid_definition
    ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      component :controllers, in: 'app/controllers/**/*.rb'
      models.cannot_use :controllers
    end
  end

  def summary_for(definition, root)
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    output = StringIO.new
    ArchSpec::Formatters::Text.print(output, graph: graph, diagnostics: ArchSpec::Evaluator.evaluate(definition, graph))
    output.string
  end
end
