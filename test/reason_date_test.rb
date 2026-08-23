# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'

class ReasonDateTest < ArchSpecTest
  def test_because_is_carried_and_printed_without_moving_the_fingerprint
    with_project do |root|
      write_models_and_controllers(root)

      plain = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end
      reasoned = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers, because: 'a model that knows the request cannot be used off it'
      end

      before = diagnostics_for(plain, root).first
      after = diagnostics_for(reasoned, root).first

      assert_equal before.fingerprint(root: root), after.fingerprint(root: root)
      assert_nil before.reason
      assert_equal 'a model that knows the request cannot be used off it', after.reason

      text = check_output(reasoned, root)
      assert_match(/note: User references UsersController/, text)
      assert_match(/reason: a model that knows the request cannot be used off it/, text)

      document = JSON.parse(json_output(reasoned, root))
      assert_equal 'a model that knows the request cannot be used off it', document['violations'].first['reason']
      assert_nil document['violations'].first['since']
      assert_nil document['violations'].first['age']
    end
  end

  def test_conflicting_reasons_on_one_rule_are_a_configuration_error
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        component :helpers, in: 'app/helpers/**/*.rb'
        models.cannot_use :controllers, because: 'one reason'
        models.cannot_use :helpers, because: 'another reason'
      end
    end

    assert_match(/dependencies\.forbid is declared twice with different reasons/, error.message)
  end

  def test_repeated_declarations_merge_their_reason_and_date
    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      component :controllers, in: 'app/controllers/**/*.rb'
      component :helpers, in: 'app/helpers/**/*.rb'
      models.cannot_use :controllers, because: 'the reason'
      models.cannot_use :helpers, since: '2024-01-01'
    end

    rule = definition.rules.first
    assert_equal 'the reason', rule.reason
    assert_equal Date.new(2024, 1, 1), rule.since
  end

  def test_a_malformed_since_date_is_refused_at_load
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.cannot_call :render, since: 'last tuesday'
      end
    end

    assert_match(/since: expects a date as YYYY-MM-DD/, error.message)
  end

  def test_every_preset_rule_carries_a_reason
    presets = {
      rails_strict: {},
      vanilla_rails: {},
      layered: {},
      hexagonal: {},
      clean: {},
      modular_monolith: { components: { billing: 'packs/billing/**/*.rb', catalog: 'packs/catalog/**/*.rb' },
                          public: { billing: 'packs/billing/app/public/**/*.rb' } },
      cqrs: {},
      event_driven: {},
      ruby_conventions: {}
    }

    presets.each do |name, options|
      definition = ArchSpec.define { architecture name, **options }
      definition.rules.each do |rule|
        assert rule.respond_to?(:reason), "#{name}: #{rule.id} carries no reason"
        refute_nil rule.reason, "#{name}: #{rule.id} carries no reason"
      end
    end
  end

  def test_the_rails_preset_prints_its_reason_on_a_breach
    with_project do |root|
      write_models_and_controllers(root)

      definition = ArchSpec.define { architecture :rails }
      text = check_output(definition, root)

      assert_match(/reason: models and services run outside a request too/, text)
    end
  end

  def test_since_reports_older_lines_and_fails_newer_ones
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      git(root, 'init', '-q')
      git(root, 'add', '.')
      commit(root, 'old breach', '2020-06-01T12:00:00Z')

      write "#{root}/app/models/user.rb", "class User\n  UsersController\n  UsersController.new\nend\n"
      git(root, 'add', '.')
      commit(root, 'new breach', '2026-03-01T12:00:00Z')

      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers, since: "2024-01-01"
      RUBY

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: output, error: StringIO.new) }

      assert_equal 1, status
      assert_match(/1 architecture violation found\./, output.string)
      assert_match(%r{^app/models/user\.rb:3:3$}, output.string)
      assert_match(/1 finding predates the rule's since: date, reported, not failed:/, output.string)
      assert_match(%r{app/models/user\.rb:2: models must not depend on controllers \[dependencies\.forbid\] \(since 2024-01-01\)},
                   output.string)
      refute_match(/could not be dated/, output.string)
    end
  end

  def test_since_passes_when_every_breach_predates_the_rule
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      git(root, 'init', '-q')
      git(root, 'add', '.')
      commit(root, 'old breach', '2020-06-01T12:00:00Z')
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers, since: "2024-01-01"
      RUBY

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_match(/ArchSpec passed/, output.string)
      assert_match(/1 finding predates/, output.string)

      document = JSON.parse(Dir.chdir(root) do
        out = StringIO.new
        ArchSpec::CLI.run(['check', '--format', 'json'], output: out, error: StringIO.new)
        out.string
      end)
      assert_equal '2024-01-01', document['violations'].first['since']
      assert_equal 'before', document['violations'].first['age']
    end
  end

  def test_since_reads_blame_with_an_accented_author_under_an_ascii_default
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      git(root, 'init', '-q')
      git(root, 'add', '.')
      commit(root, 'old breach', '2020-06-01T12:00:00Z', author: 'Zoë Müller')
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers, since: "2024-01-01"
      RUBY

      verdict = with_default_external(Encoding::US_ASCII) do
        ArchSpec::LineAge.new(root).verdict('app/models/user.rb', 2, Date.new(2024, 1, 1))
      end

      assert_equal :before, verdict
    end
  end

  def test_since_asks_git_once_per_witness_file
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  UsersController\n  UsersController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      git(root, 'init', '-q')
      git(root, 'add', '.')
      commit(root, 'old breach', '2020-06-01T12:00:00Z')

      ages = ArchSpec::LineAge.new(root)
      calls = 0
      ages.define_singleton_method(:blame) { |path| calls += 1; super(path) }
      ages.verdict('app/models/user.rb', 2, Date.new(2024, 1, 1))
      ages.verdict('app/models/user.rb', 3, Date.new(2024, 1, 1))

      assert_equal 1, calls
    end
  end

  def test_since_without_git_counts_as_undated_and_says_so_once
    with_project do |root|
      write_models_and_controllers(root)
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers, since: "2024-01-01"
      RUBY

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: output, error: StringIO.new) }

      assert_equal 1, status
      assert_match(/since: 2024-01-01, this line could not be dated, so the finding counts as undated/, output.string)
      assert_equal 1, output.string.scan(/since: some findings could not be dated/).size
    end
  end

  private

  def write_models_and_controllers(root)
    write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
    write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
  end

  def check_output(definition, root)
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
    output = StringIO.new
    ArchSpec::Formatters::Text.print(output, graph: graph, diagnostics: diagnostics)
    output.string
  end

  def json_output(definition, root)
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
    output = StringIO.new
    ArchSpec::Formatters::JSON.print(output, graph: graph, diagnostics: diagnostics)
    output.string
  end

  def git(root, *args)
    system('git', '-C', root, *args, out: File::NULL, err: File::NULL) || raise("git #{args.join(' ')} failed")
  end

  def with_default_external(encoding)
    previous = Encoding.default_external
    verbose, $VERBOSE = $VERBOSE, nil
    Encoding.default_external = encoding
    yield
  ensure
    Encoding.default_external = previous
    $VERBOSE = verbose
  end

  def commit(root, message, date, author: 'test')
    env = {
      'GIT_AUTHOR_DATE' => date, 'GIT_COMMITTER_DATE' => date,
      'GIT_AUTHOR_NAME' => author, 'GIT_AUTHOR_EMAIL' => 'test@example.com',
      'GIT_COMMITTER_NAME' => 'test', 'GIT_COMMITTER_EMAIL' => 'test@example.com'
    }
    system(env, 'git', '-C', root, 'commit', '-q', '-m', message, out: File::NULL, err: File::NULL) ||
      raise('git commit failed')
  end

  def test_two_protocol_rules_on_one_component_may_carry_different_dates
    definition = ArchSpec.define do
      component :commands, in: 'app/commands/**/*.rb'
      commands.must_implement :call, since: '2024-01-01'
      commands.must_implement :undo, since: '2025-01-01'
    end

    assert_equal [Date.new(2024, 1, 1), Date.new(2025, 1, 1)], definition.rules.map(&:since)
  end

  def test_a_line_at_the_edge_of_a_shallow_clone_counts_as_undated
    ages = ArchSpec::LineAge.new('/nowhere')
    ages.instance_variable_set(:@shallow, true)
    dates = ages.send(:parse, <<~PORCELAIN)
      abcdefabcdefabcdefabcdefabcdefabcdefabcd 1 1 1
      author a
      author-time 1700000000
      boundary
      	class User
    PORCELAIN

    assert_equal ArchSpec::LineAge::BOUNDARY, dates[1]
  end

  def test_the_rails_preset_names_helpers_in_its_reason_only_when_they_are_forbidden
    strict = ArchSpec.define { architecture :rails }
    shared = ArchSpec.define { architecture :rails, share_helpers: true }
    reason = ->(definition) { definition.rules.find { |rule| rule.id == 'dependencies.forbid' }.reason }

    assert_match(/or its view helpers/, reason.call(strict))
    refute_match(/helpers/, reason.call(shared))
  end

  def test_a_must_be_empty_breach_carries_its_reason_once
    with_project do |root|
      write "#{root}/app/services/thing.rb", "class Thing; end\n"
      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.must_be_empty because: 'services hide what models should say'
      end

      diagnostic = diagnostics_for(definition, root).first

      assert_equal 'services must stay empty: services hide what models should say', diagnostic.message
      assert_nil diagnostic.reason
    end
  end
end
