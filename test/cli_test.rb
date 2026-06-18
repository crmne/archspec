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
