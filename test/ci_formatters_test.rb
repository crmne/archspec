# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'

class CiFormattersTest < ArchSpecTest
  SARIF_LEVELS = %w[none note warning error].freeze

  def test_github_format_prints_one_workflow_command_per_finding_and_notices_for_the_rest
    with_project do |root|
      write_app(root, rules: 'models.cannot_use :controllers, because: "a model that knows the request, cannot be used off it"')
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"

      output = StringIO.new
      status = check(root, ['--format', 'github'], output)
      lines = output.string.lines.map(&:chomp)

      assert_equal 1, status
      assert_equal '::error file=app/models/user.rb,line=2,col=3,endLine=2,endColumn=18,title=dependencies.forbid' \
                   '::models must not depend on controllers. Reason: a model that knows the request, cannot be used off it. ' \
                   'Action: no cut the graph can see.', lines[0]
      assert_equal '::notice title=archspec::facts: none (archspec_facts/ absent)', lines[1]
      assert_match(/\A::notice title=archspec::could not see: /, lines[2])
      assert_equal 3, lines.size
    end
  end

  def test_github_format_encodes_newlines_and_commas_the_way_the_runner_decodes_them
    assert_equal 'a%25b%0Ac', ArchSpec::Formatters::GitHub.escape_data("a%b\nc")
    assert_equal 'a%3Ab%2Cc', ArchSpec::Formatters::GitHub.escape_property('a:b,c')
  end

  def test_github_format_maps_delta_buckets_to_levels_by_mode
    with_project do |root|
      write_app(root)
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      assert_equal 0, snapshot(root)
      write "#{root}/app/models/post.rb", "class Post\n  UsersController\nend\n"

      ratchet = StringIO.new
      assert_equal 1, check(root, ['--baseline', '--format', 'github'], ratchet)
      assert_match(%r{\A::error file=app/models/post\.rb,.*title=dependencies\.forbid::}, ratchet.string)
      refute_match(/carried/, ratchet.string)

      strict = StringIO.new
      assert_equal 1, check(root, ['--baseline', '--mode', 'strict', '--format', 'github'], strict)
      assert_match(%r{^::warning file=app/models/user\.rb,.*title=dependencies\.forbid carried::}, strict.string)
    end
  end

  def test_sarif_format_is_a_single_run_with_rules_results_and_fingerprints
    with_project do |root|
      write_app(root, rules: 'models.cannot_use :controllers, because: "models and services run outside a request too"')
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"

      output = StringIO.new
      status = check(root, ['--format', 'sarif'], output)
      log = JSON.parse(output.string)

      assert_equal 1, status
      assert_sarif_shape(log)
      run = log.fetch('runs').fetch(0)
      assert_equal 'archspec', run.dig('tool', 'driver', 'name')
      assert_equal ArchSpec::VERSION, run.dig('tool', 'driver', 'version')

      rule = run.dig('tool', 'driver', 'rules').fetch(0)
      assert_equal 'dependencies.forbid', rule.fetch('id')
      assert_equal 'https://archspecrb.dev/rules/dependencies/', rule.fetch('helpUri')
      assert_match(/models and services run outside a request/, rule.dig('shortDescription', 'text'))

      result = run.fetch('results').fetch(0)
      assert_equal 'dependencies.forbid', result.fetch('ruleId')
      assert_equal 0, result.fetch('ruleIndex')
      assert_equal 'error', result.fetch('level')
      assert_equal 'models must not depend on controllers', result.dig('message', 'text')
      location = result.fetch('locations').fetch(0).fetch('physicalLocation')
      assert_equal 'app/models/user.rb', location.dig('artifactLocation', 'uri')
      assert_equal({ 'startLine' => 2, 'startColumn' => 3, 'endLine' => 2, 'endColumn' => 18 }, location.fetch('region'))
      assert_match(/\A\h{24}\z/, result.dig('partialFingerprints', 'archspec/v1'))
      assert_equal 'high', result.dig('properties', 'confidence')
      assert_equal 'User references UsersController', result.dig('properties', 'evidence')
      refute result.fetch('properties').key?('bucket')
      assert_equal 2, run.dig('properties', 'files')
    end
  end

  def test_sarif_format_is_stable_across_runs
    with_project do |root|
      write_app(root)
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"

      first = StringIO.new
      second = StringIO.new
      check(root, ['--format', 'sarif'], first)
      check(root, ['--format', 'sarif'], second)

      assert_equal first.string, second.string
    end
  end

  def test_sarif_format_under_a_baseline_carries_the_bucket_and_the_mode
    with_project do |root|
      write_app(root)
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      assert_equal 0, snapshot(root)
      write "#{root}/app/models/user.rb", "class User\nend\n"
      write "#{root}/app/models/post.rb", "class Post\n  UsersController\nend\n"

      output = StringIO.new
      status = check(root, ['--baseline', '--format', 'sarif'], output)
      log = JSON.parse(output.string)

      assert_equal 1, status
      assert_sarif_shape(log)
      run = log.fetch('runs').fetch(0)
      buckets = run.fetch('results').to_h do |result|
        [result.dig('locations', 0, 'physicalLocation', 'artifactLocation', 'uri'), result.dig('properties', 'bucket')]
      end
      assert_equal({ 'app/models/post.rb' => 'introduced', 'app/models/user.rb' => 'resolved' }, buckets)
      resolved = run.fetch('results').find { |result| result.dig('properties', 'bucket') == 'resolved' }
      assert_equal 'none', resolved.fetch('level')
      assert_equal 'ratchet', run.dig('properties', 'mode')
      assert_equal({ 'added' => { 'references_constant' => 1 }, 'removed' => { 'references_constant' => 1 } },
                   run.dig('properties', 'edges'))
    end
  end

  def test_sarif_help_uri_falls_back_to_the_cli_page_for_rules_without_a_family_page
    assert_equal 'https://archspecrb.dev/rules/protocols/', ArchSpec::Formatters::SARIF.help_uri('protocol.must_implement')
    assert_equal 'https://archspecrb.dev/cli/', ArchSpec::Formatters::SARIF.help_uri('housekeeping.stale_todo')
    assert_equal 'https://archspecrb.dev/cli/', ArchSpec::Formatters::SARIF.help_uri('parser.syntax')
  end

  def test_a_formatter_registered_from_the_spec_is_selectable_by_name
    with_project do |root|
      write_app(root, rules: <<~RUBY)
        models.cannot_use :controllers
        formatter :count, Module.new {
          def self.print(output, graph:, diagnostics:)
            output.puts "\#{diagnostics.size} over \#{graph.files.size} files"
          end
        }
      RUBY
      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"

      output = StringIO.new
      status = check(root, ['--format', 'count'], output)

      assert_equal 1, status
      assert_equal "1 over 2 files\n", output.string
    end
  end

  def test_a_registered_formatter_without_print_delta_cannot_print_a_baseline_check
    with_project do |root|
      write_app(root, rules: <<~RUBY)
        models.cannot_use :controllers
        formatter :count, Module.new {
          def self.print(output, graph:, diagnostics:); end
        }
      RUBY
      assert_equal 0, snapshot(root)

      error = StringIO.new
      status = check(root, ['--baseline', '--format', 'count'], error)

      assert_equal 64, status
      assert_match(/format "count" cannot print a baseline check; .* has no print_delta/, error.string)
    end
  end

  def test_a_registered_formatter_must_respond_to_print
    with_project do |root|
      write_app(root, rules: "models.cannot_use :controllers\nformatter :broken, Object.new")

      error = StringIO.new
      status = check(root, ['--format', 'broken'], error)

      assert_equal 1, status
      assert_match(/formatter :broken must respond to print/, error.string)
    end
  end

  def test_an_unknown_format_lists_the_registered_names
    with_project do |root|
      write_app(root)

      error = StringIO.new
      status = check(root, ['--format', 'xml'], error)

      assert_equal 64, status
      assert_match(/unknown format: "xml" \(registered: text, json, github, sarif\)/, error.string)
    end
  end

  private

  def assert_sarif_shape(log)
    assert_equal 'https://docs.oasis-open.org/sarif/sarif/v2.1.0/errata01/os/schemas/sarif-schema-2.1.0.json',
                 log.fetch('$schema')
    assert_equal '2.1.0', log.fetch('version')
    assert_equal 1, log.fetch('runs').size
    run = log.fetch('runs').fetch(0)
    driver = run.dig('tool', 'driver')
    assert driver.key?('name')
    driver.fetch('rules').each do |rule|
      assert rule.key?('id')
      assert rule.dig('shortDescription', 'text')
    end
    rule_ids = driver.fetch('rules').map { |rule| rule.fetch('id') }
    run.fetch('results').each do |result|
      assert_includes rule_ids, result.fetch('ruleId')
      assert_equal rule_ids.index(result.fetch('ruleId')), result.fetch('ruleIndex')
      assert_includes SARIF_LEVELS, result.fetch('level')
      assert result.dig('message', 'text')
      result.fetch('locations').each do |location|
        physical = location.fetch('physicalLocation')
        assert physical.dig('artifactLocation', 'uri')
        %w[startLine startColumn endLine endColumn].each do |key|
          assert_kind_of Integer, physical.dig('region', key)
        end
      end
      assert result.fetch('partialFingerprints').key?('archspec/v1')
    end
  end

  def write_app(root, rules: 'models.cannot_use :controllers')
    write "#{root}/Archspec.rb", <<~RUBY
      component :models, in: "app/models/**/*.rb"
      component :controllers, in: "app/controllers/**/*.rb"
      #{rules}
    RUBY
    write "#{root}/app/models/user.rb", "class User\nend\n" unless File.exist?("#{root}/app/models/user.rb")
    write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
  end

  def snapshot(root)
    Dir.chdir(root) { ArchSpec::CLI.run(['snapshot'], output: StringIO.new, error: StringIO.new) }
  end

  def check(root, argv, output)
    Dir.chdir(root) { ArchSpec::CLI.run(['check', *argv], output: output, error: output) }
  end

  def test_a_shipped_format_name_cannot_be_registered_over
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define { formatter 'text', Object.new.tap { |o| o.define_singleton_method(:print) { |*| } } }
    end

    assert_match(/"text" is shipped with archspec/, error.message)
  end
end
