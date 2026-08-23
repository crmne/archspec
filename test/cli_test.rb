# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class CLITest < ArchSpecTest
  def test_global_help_and_version
    help = StringIO.new
    version = StringIO.new

    help_status = ArchSpec::CLI.run(['help'], output: help, error: StringIO.new)
    version_status = ArchSpec::CLI.run(['version'], output: version, error: StringIO.new)

    assert_equal 0, help_status
    assert_match(/archspec help \[COMMAND\]/, help.string)
    assert_equal 0, version_status
    assert_equal "#{ArchSpec::VERSION}\n", version.string
  end

  def test_unknown_commands_are_usage_errors
    error = StringIO.new

    status = ArchSpec::CLI.run(['frobnicate'], output: StringIO.new, error: error)

    assert_equal 64, status
    assert_match(/archspec: error: unknown command: frobnicate/, error.string)
  end

  def test_help_is_returned_without_exiting_the_caller
    output = StringIO.new

    status = ArchSpec::CLI.run(['check', '--help'], output: output, error: StringIO.new)

    assert_equal 0, status
    assert_match(/Usage: archspec check/, output.string)
  end

  def test_invalid_options_are_usage_errors_and_init_does_not_create_them
    with_project do |root|
      error = StringIO.new
      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['init', '--wat'], output: StringIO.new, error: error)
      end

      assert_equal 64, status
      assert_match(/invalid option: --wat/, error.string)
      refute_path_exists "#{root}/--wat"
    end
  end

  def test_config_syntax_errors_are_reported_without_escaping_the_cli
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: \"app/models/**/*.rb\"\n{\n"
      error = StringIO.new

      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['check'], output: StringIO.new, error: error)
      end

      assert_equal 1, status
      assert_match(/archspec: error: could not load Archspec\.rb/, error.string)
      assert_match(/syntax error/i, error.string)
    end
  end

  def test_malformed_todo_files_are_reported_without_escaping_the_cli
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        todo "archspec_todo.yml"
      RUBY
      write "#{root}/archspec_todo.yml", "violations: [\n"
      error = StringIO.new

      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['check'], output: StringIO.new, error: error)
      end

      assert_equal 1, status
      assert_match(/could not load todo file/, error.string)
    end
  end

  def test_init_uses_default_root
    with_project do |root|
      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['init'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_match(/Created Archspec\.rb/, output.string)

      config = File.read("#{root}/Archspec.rb")
      refute_match(/ArchSpec\.define/, config)
      refute_match(/root\s+["']\./, config)
      refute_match(/preset/, config)
      assert_match(/architecture :rails/, config)
    end
  end

  def test_init_protects_existing_files_unless_forced
    with_project do |root|
      write "#{root}/Architecture.rb", "existing\n"
      error = StringIO.new

      protected_status = Dir.chdir(root) do
        ArchSpec::CLI.run(['init', 'Architecture.rb'], output: StringIO.new, error: error)
      end
      forced_status = Dir.chdir(root) do
        ArchSpec::CLI.run(['init', 'Architecture.rb', '--force'], output: StringIO.new, error: StringIO.new)
      end

      assert_equal 1, protected_status
      assert_match(/already exists/, error.string)
      assert_equal 0, forced_status
      assert_equal "architecture :rails\n", File.read("#{root}/Architecture.rb")
    end
  end

  def test_check_returns_nonzero_on_violations
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers
      RUBY

      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: output, error: StringIO.new) }

      assert_equal 1, status
      assert_match(/architecture violation/, output.string)
      assert_match(/dependencies.forbid/, output.string)
    end
  end

  def test_check_rejects_wrapped_definitions
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        ArchSpec.define do
          component :models, in: "app/models/**/*.rb"
        end
      RUBY

      write "#{root}/app/models/user.rb", "class User; end\n"

      error = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: StringIO.new, error: error) }

      assert_equal 1, status
      assert_match(/declared no components or rules/, error.string)
      assert_match(/do not wrap declarations in ArchSpec\.define/, error.string)
    end
  end

  def test_config_resolves_immediate_dsl_operations_from_its_own_directory
    with_project do |root|
      write "#{root}/config/architecture.rb", <<~RUBY
        root ".."
        source "engines/*/app/**/*.rb"
        each_directory "engines/*" do |name, path|
          component name, in: "\#{path}/**/*.rb"
        end
      RUBY
      write "#{root}/engines/billing/app/models/invoice.rb", "class Invoice; end\n"

      output = StringIO.new
      status = Dir.chdir(root) do
        ArchSpec::CLI.run(
          ['check', '--config', 'config/architecture.rb'],
          output: output,
          error: StringIO.new
        )
      end

      assert_equal 0, status
      assert_match(/1 files, 1 constants/, output.string)
    end
  end

  def test_check_scopes_output_to_given_paths
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers
      RUBY

      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/models/account.rb", "class Account; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      output = StringIO.new
      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['check', 'app/models/account.rb'], output: output, error: StringIO.new)
      end

      assert_equal 1, status
      assert_match(/account\.rb/, output.string)
      refute_match(/user\.rb:/, output.string)

      clean_output = StringIO.new
      clean_status = Dir.chdir(root) do
        ArchSpec::CLI.run(['check', 'app/controllers'], output: clean_output, error: StringIO.new)
      end

      assert_equal 0, clean_status
    end
  end

  def test_check_rejects_paths_with_update_todo
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: \"app/models/**/*.rb\"\n"
      write "#{root}/app/models/user.rb", "class User; end\n"

      error = StringIO.new
      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['check', '--update-todo', 'app/models'], output: StringIO.new, error: error)
      end

      assert_equal 1, status
      assert_match(/cannot combine/, error.string)
    end
  end

  def test_check_requires_a_configured_todo_before_updating
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: \"app/models/**/*.rb\"\n"
      error = StringIO.new

      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['check', '--update-todo'], output: StringIO.new, error: error)
      end

      assert_equal 1, status
      assert_match(/no todo configured/, error.string)
    end
  end

  def test_check_rejects_unknown_formats_before_loading_the_project
    error = StringIO.new

    status = ArchSpec::CLI.run(['check', '--format', 'xml'], output: StringIO.new, error: error)

    assert_equal 64, status
    assert_match(/unknown format: "xml"/, error.string)
  end

  def test_check_updates_todo_file
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers
        todo "archspec_todo.yml"
      RUBY
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check', '--update-todo'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_match(/Updated archspec_todo\.yml with 1 violation\./, output.string)
      assert_path_exists "#{root}/archspec_todo.yml"

      recheck = StringIO.new
      recheck_status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: recheck, error: StringIO.new) }

      assert_equal 0, recheck_status
      assert_match(/ArchSpec passed/, recheck.string)
    end
  end

  def test_update_todo_never_accepts_parse_errors
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
        todo "archspec_todo.yml"
      RUBY
      write "#{root}/app/models/user.rb", "class User\n  def call\n"

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check', '--update-todo'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_match(/with 0 violations/, output.string)

      recheck = StringIO.new
      recheck_status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: recheck, error: StringIO.new) }

      assert_equal 1, recheck_status
      assert_match(/parser\.syntax/, recheck.string)
    end
  end

  def test_json_format
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
      RUBY

      write "#{root}/app/models/user.rb", "class User; end\n"

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check', '--format', 'json'], output: output, error: StringIO.new) }

      assert_equal 0, status
      parsed = JSON.parse(output.string)
      assert_equal 1, parsed.fetch('files')
      assert_equal [], parsed.fetch('violations')
    end
  end

  def test_explain_file
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
      RUBY

      write "#{root}/app/models/user.rb", "class User; end\n"

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['explain', 'app/models/user.rb'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_match(/defined constants: User/, output.string)
      assert_match(%r{components:\n    models: matched file pattern app/models/\*\*/\*\.rb}, output.string)
    end
  end

  def test_explain_file_names_the_pattern_that_excluded_it
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :domain, in: "app/models/**/*.rb", except: "app/models/**/*_workflow.rb"
      RUBY

      write "#{root}/app/models/checkout_workflow.rb", "class CheckoutWorkflow; end\n"

      output = StringIO.new
      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['explain', 'app/models/checkout_workflow.rb'], output: output, error: StringIO.new)
      end

      assert_equal 0, status
      assert_match(/components: \(none\)/, output.string)
      assert_match(%r{excluded from:\n    domain: excluded by except pattern app/models/\*\*/\*_workflow\.rb}, output.string)
    end
  end

  def test_explain_file_includes_suppressions
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
      RUBY

      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          # archspec:disable-next-line dependencies.forbid -- accepted boundary
          UsersController
        end
      RUBY

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['explain', 'app/models/user.rb'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_match(/suppressions:/, output.string)
      assert_match(/3 │ dependencies\.forbid -- accepted boundary/, output.string)
    end
  end

  def test_explain_constant
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        component :models, in: "app/models/**/*.rb"
      RUBY
      write "#{root}/app/models/user.rb", <<~RUBY
        class User < ApplicationRecord
          def name; end
          def self.find; end
        end
      RUBY

      output = StringIO.new
      status = Dir.chdir(root) do
        ArchSpec::CLI.run(['explain', 'User'], output: output, error: StringIO.new)
      end

      assert_equal 0, status
      assert_match(/kind: class/, output.string)
      assert_match(/superclass: ApplicationRecord/, output.string)
      assert_match(/instance methods: name/, output.string)
      assert_match(/class methods: find/, output.string)
    end
  end
  def test_reflect_runs_inside_the_app_through_bin_rails_runner
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"
      write "#{root}/app/models/user.rb", "class User; end\n"
      facts = { 'format' => 1, 'producer' => 'archspec-reflect', 'producer_version' => '1.0.1', 'commit' => nil,
                'dirty' => false, 'references' => [], 'generated_methods' => [], 'misses' => {} }
      write "#{root}/bin/rails", <<~SH
        #!/bin/sh
        printf '%s\\n' "$@" > "#{root}/runner-args"
        mkdir -p "#{root}/archspec_facts"
        cat > "#{root}/archspec_facts/rails.yml" <<'YAML'
        #{facts.to_yaml}
        YAML
      SH
      File.chmod(0o755, "#{root}/bin/rails")

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['reflect'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_equal 'Wrote archspec_facts/rails.yml', output.string.lines.first.strip
      args = File.readlines("#{root}/runner-args", chomp: true)
      assert_equal 'runner', args.first
      assert_match "ArchSpec::Reflect.run(output: \"#{root}/archspec_facts/rails.yml\", root: \"#{root}\")", args.last
      assert_match "$LOAD_PATH.unshift(#{File.expand_path('../lib', __dir__).inspect})", args.last
    end
  end

  def test_reflect_prints_the_summary_of_the_file_the_runner_wrote
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"
      write "#{root}/app/models/user.rb", "class User; end\n"
      facts = { 'format' => 1, 'producer' => 'archspec-reflect', 'producer_version' => '1.0.1', 'commit' => nil,
                'dirty' => false, 'references' => [], 'generated_methods' => [], 'misses' => { 'polymorphic' => 2 } }
      write "#{root}/bin/rails", <<~SH
        #!/bin/sh
        mkdir -p "#{root}/archspec_facts"
        cat > "#{root}/archspec_facts/rails.yml" <<'YAML'
        #{facts.to_yaml}
        YAML
      SH
      File.chmod(0o755, "#{root}/bin/rails")

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['reflect'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_equal ['Wrote archspec_facts/rails.yml', '0 references; misses: polymorphic 2'], output.string.lines.map(&:strip)
    end
  end

  def test_reflect_refuses_outside_a_rails_application
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"

      error = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['reflect'], output: StringIO.new, error: error) }

      assert_equal 1, status
      assert_match 'no bin/rails', error.string
    end
  end

  def test_reflect_reports_a_failed_runner
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"
      write "#{root}/bin/rails", "#!/bin/sh\necho 'boom: no database' >&2\nexit 3\n"
      File.chmod(0o755, "#{root}/bin/rails")

      error = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['reflect', '--output', 'tmp/facts.yml'], output: StringIO.new, error: error) }

      assert_equal 1, status
      assert_match 'bin/rails runner failed', error.string
      assert_match 'boom: no database', error.string
    end
  end

end
