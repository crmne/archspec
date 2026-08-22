# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'

class SnapshotTest < ArchSpecTest
  def test_snapshot_round_trips_the_graph
    with_project do |root|
      write_app(root)
      definition = definition_for(root)
      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      ArchSpec::Snapshot.write("#{root}/.archspec", graph: graph, definition: definition,
                                                    definition_digest: 'abc', commit: nil, dirty: false)
      restored = ArchSpec::Snapshot.load("#{root}/.archspec", root: root)

      assert_equal graph.files.keys, restored.graph.files.keys
      assert_equal graph.constants.map(&:name), restored.graph.constants.map(&:name)
      assert_equal graph.edges, restored.graph.edges
      assert_equal graph.components.keys, restored.graph.components.keys
      assert_equal graph.components[:models].files, restored.graph.components[:models].files
      assert_equal %w[dependencies.forbid], restored.receipt.rule_ids
      assert_equal "*\n", File.read("#{root}/.archspec/.gitignore")

      before = ArchSpec::Evaluator.evaluate(definition, graph).map { |d| d.fingerprint(root: root) }
      after = ArchSpec::Evaluator.evaluate(definition, restored.graph).map { |d| d.fingerprint(root: root) }
      assert_equal before, after
    end
  end

  def test_two_snapshots_of_the_same_tree_are_identical
    with_project do |root|
      write_app(root)
      first = snapshot(root, '.one')
      second = snapshot(root, '.two')

      assert_equal 0, first
      assert_equal 0, second
      assert_equal File.read("#{root}/.one/graph.yml"), File.read("#{root}/.two/graph.yml")
      assert_equal File.read("#{root}/.one/receipt.yml"), File.read("#{root}/.two/receipt.yml")
      refute_match(/\d{4}-\d{2}-\d{2}/, File.read("#{root}/.one/receipt.yml"))
    end
  end

  def test_check_against_a_baseline_reports_what_the_change_introduced_and_resolved
    with_project do |root|
      write_app(root)
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      assert_equal 0, snapshot(root)

      write "#{root}/app/models/user.rb", "class User\nend\n"
      write "#{root}/app/models/post.rb", "class Post\n  PostsController\nend\n"
      write "#{root}/app/controllers/posts_controller.rb", "class PostsController; end\n"

      output = StringIO.new
      status = check(root, ['--baseline'], output)

      assert_equal 1, status
      assert_match(/introduced \(1\)/, output.string)
      assert_match(/app\/models\/post\.rb/, output.string)
      assert_match(/resolved \(1\)/, output.string)
      assert_match(/app\/models\/user\.rb: models must not depend on controllers/, output.string)
      assert_match(/Architecture regressed \(ratchet\): 1 introduced, 1 resolved, 0 declared, 0 carried/, output.string)
      assert_match(/edges: .*\+1 references_constant/, output.string)
    end
  end

  def test_a_carried_breach_passes_the_ratchet_and_fails_strict
    with_project do |root|
      write_app(root)
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      assert_equal 0, snapshot(root)

      ratchet = StringIO.new
      strict = StringIO.new
      advisory = StringIO.new

      assert_equal 0, check(root, ['--baseline'], ratchet)
      assert_match(/Architecture held \(ratchet\): 0 introduced, 0 resolved, 0 declared, 1 carried/, ratchet.string)
      refute_match(/carried \(1\)/, ratchet.string)

      assert_equal 1, check(root, ['--baseline', '--mode', 'strict'], strict)
      assert_match(/carried \(1\)/, strict.string)

      assert_equal 0, check(root, ['--baseline', '--mode', 'advisory'], advisory)
    end
  end

  def test_a_newly_declared_rule_reads_as_declared_in_untouched_files_and_introduced_in_touched_ones
    with_project do |root|
      write_app(root, rules: '')
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      write "#{root}/app/models/post.rb", "class Post\nend\n"
      git(root, 'init', '-q')
      git(root, 'add', '.')
      git(root, '-c', 'user.name=a', '-c', 'user.email=a@b', 'commit', '-q', '-m', 'before')
      assert_equal 0, snapshot(root)

      write_app(root)
      write "#{root}/app/models/post.rb", "class Post\n  PostsController\nend\n"
      write "#{root}/app/controllers/posts_controller.rb", "class PostsController; end\n"

      output = StringIO.new
      status = check(root, ['--baseline'], output)

      assert_equal 1, status
      assert_match(/declared \(1\)/, output.string)
      assert_match(/user\.rb[\s\S]*declared by this change, pre-existing in the file/, output.string)
      assert_match(/introduced \(1\)/, output.string)
      assert_match(/post\.rb/, output.string)
      assert_match(/changed files: read from git/, output.string)
    end
  end

  def test_without_git_a_newly_declared_rule_counts_as_introduced_and_says_so
    with_project do |root|
      write_app(root, rules: '')
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      assert_equal 0, snapshot(root)
      write_app(root)

      output = StringIO.new
      status = check(root, ['--baseline'], output)

      assert_equal 1, status
      assert_match(/introduced \(1\)/, output.string)
      assert_match(/changed files: not read/, output.string)
    end
  end

  def test_a_snapshot_from_a_different_version_or_parsed_set_declines
    with_project do |root|
      write_app(root)
      assert_equal 0, snapshot(root)

      receipt = File.read("#{root}/.archspec/receipt.yml")
      File.write("#{root}/.archspec/receipt.yml", receipt.sub(/archspec_version: .*/, 'archspec_version: 0.0.1'))
      output = StringIO.new
      assert_equal 3, check(root, ['--baseline'], output)
      assert_match(/archspec: declined: the snapshot was taken with archspec 0\.0\.1/, output.string)
      refute_match(/Architecture/, output.string)

      File.write("#{root}/.archspec/receipt.yml", receipt)
      write "#{root}/Archspec.rb", "#{File.read("#{root}/Archspec.rb")}\nignore \"app/models/**/*.rb\"\n"
      output = StringIO.new
      assert_equal 3, check(root, ['--baseline'], output)
      assert_match(/declined: the source or ignore patterns changed/, output.string)
    end
  end

  def test_json_carries_the_delta_beside_the_violations
    with_project do |root|
      write_app(root)
      assert_equal 0, snapshot(root)
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"

      output = StringIO.new
      check(root, ['--baseline', '--format', 'json'], output)
      document = JSON.parse(output.string)

      assert_equal 1, document['violations'].size
      assert_equal 1, document['introduced'].size
      assert_equal [], document['resolved']
      assert_equal [], document['declared']
      assert_equal 0, document['carried']
      assert_equal 'ratchet', document['mode']
      assert_equal %w[dependencies.forbid], document['baseline']['rule_ids']
      assert_equal({ 'references_constant' => 1 }, document['edges']['added'])
    end
  end

  def test_baseline_options_are_checked
    with_project do |root|
      write_app(root)
      assert_equal 64, check(root, ['--mode', 'strict'], StringIO.new)
      assert_equal 64, check(root, ['--baseline', '--mode', 'loose'], StringIO.new)
      assert_equal 1, check(root, ['--baseline'], StringIO.new)
    end
  end

  private

  def write_app(root, rules: 'models.cannot_use :controllers')
    write "#{root}/Archspec.rb", <<~RUBY
      component :models, in: "app/models/**/*.rb"
      component :controllers, in: "app/controllers/**/*.rb"
      #{rules}
    RUBY
    write "#{root}/app/models/user.rb", "class User\nend\n" unless File.exist?("#{root}/app/models/user.rb")
    write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
  end

  def definition_for(root)
    definition = ArchSpec::Definition.new
    definition.base_dir = root
    definition.extend(ArchSpec::DSL::Context)
    definition.instance_eval(File.read("#{root}/Archspec.rb"), "#{root}/Archspec.rb")
    definition
  end

  def snapshot(root, directory = nil)
    argv = ['snapshot']
    argv += ['--output', directory] if directory
    Dir.chdir(root) { ArchSpec::CLI.run(argv, output: StringIO.new, error: StringIO.new) }
  end

  def check(root, argv, output)
    Dir.chdir(root) { ArchSpec::CLI.run(['check', *argv], output: output, error: output) }
  end

  def git(root, *args)
    system('git', '-C', root, *args, out: File::NULL, err: File::NULL)
  end
end
