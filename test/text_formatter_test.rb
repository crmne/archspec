# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class TextFormatterTest < ArchSpecTest
  def test_diagnostics_render_as_code_frames_with_notes
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          UsersController
        end
      RUBY
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      text = check_output(definition, root)

      assert_match(/\[error\] models must not depend on controllers \[dependencies\.forbid\]/, text)
      assert_match(%r{^app/models/user\.rb:2:3$}, text)
      assert_match(/    1 │ class User$/, text)
      assert_match(/  → 2 │   UsersController$/, text)
      assert_match(/    │   \^~{14}$/, text)
      assert_match(/    3 │ end$/, text)
      assert_match(/note: User references UsersController/, text)
      assert_match(/1 architecture violation found\./, text)
      refute_match(/\e\[/, text) # StringIO is not a TTY, so no ANSI colors
    end
  end

  def test_file_level_diagnostics_underline_a_single_column
    with_project do |root|
      write "#{root}/app/services/create_user.rb", "class CreateUser; end\n"

      definition = ArchSpec.define do
        component(:services, in: 'app/services/**/*.rb').must_be_empty(because: 'behavior belongs on models')
      end

      text = check_output(definition, root)

      assert_match(/\[error\] services must stay empty: behavior belongs on models \[components\.empty\]/, text)
      assert_match(/→ 1 │ class CreateUser; end$/, text)
      assert_match(/  │ \^$/, text)
      assert_match(%r{note: app/services/create_user\.rb belongs to services}, text)
    end
  end

  def test_medium_confidence_is_noted
    with_project do |root|
      write "#{root}/app/commands/import_users.rb", "class ImportUsers < SomeGem::Base\nend\n"

      definition = ArchSpec.define do
        component :commands, in: 'app/commands/**/*.rb'
        commands.must_implement :perform
      end

      text = check_output(definition, root)

      assert_match(/unresolved ancestors: SomeGem::Base \(confidence: medium\)/, text)
    end
  end

  private

  def check_output(definition, root)
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
    output = StringIO.new
    ArchSpec::Formatters::Text.print(output, graph: graph, diagnostics: diagnostics)
    output.string
  end
end
