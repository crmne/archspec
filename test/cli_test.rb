# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class CLITest < ArchSpecTest
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

  def test_check_supports_wrapped_definition
    with_project do |root|
      write "#{root}/Archspec.rb", <<~RUBY
        ArchSpec.define do
          component :models, in: "app/models/**/*.rb"
        end
      RUBY

      write "#{root}/app/models/user.rb", "class User; end\n"

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_match(/ArchSpec passed/, output.string)
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
      assert_match(/Cannot combine/, error.string)
    end
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
      assert_match(/Updated archspec_todo\.yml with 1 violations/, output.string)
      assert_path_exists "#{root}/archspec_todo.yml"

      recheck = StringIO.new
      recheck_status = Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: recheck, error: StringIO.new) }

      assert_equal 0, recheck_status
      assert_match(/ArchSpec passed/, recheck.string)
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
      assert_match(/expected constant: User/, output.string)
      assert_match(%r{components:\n    models: matched file pattern app/models/\*\*/\*\.rb}, output.string)
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
      assert_match(/dependencies\.forbid on line 3 -- accepted boundary/, output.string)
    end
  end
end
