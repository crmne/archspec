# frozen_string_literal: true

require 'test_helper'

class TodoTest < ArchSpecTest
  def test_todo_uses_root_relative_fingerprints
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
      todo_path = "#{root}/archspec_todo.yml"

      ArchSpec::Todo.write(todo_path, diagnostics, root: root)
      todo = ArchSpec::Todo.load(todo_path, root: root)

      assert_empty ArchSpec::Evaluator.evaluate(definition, graph, todo: todo)
      assert_match 'app/models/user.rb', File.read(todo_path)
      refute_match root, File.read(todo_path)
    end
  end

  def test_todo_survives_line_shifts
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
      todo_path = "#{root}/archspec_todo.yml"
      ArchSpec::Todo.write(todo_path, diagnostics, root: root)

      write "#{root}/app/models/user.rb", <<~RUBY
        # a comment
        # another comment
        class User
          UsersController
        end
      RUBY

      shifted_graph = ArchSpec::Analyzer.analyze(definition, root: root)
      todo = ArchSpec::Todo.load(todo_path, root: root)

      assert_empty ArchSpec::Evaluator.evaluate(definition, shifted_graph, todo: todo)
    end
  end

  # A mixin raises both an includes and a references diagnostic for the same
  # statement. The todo has to suppress the pair, not just the one it recorded.
  def test_todo_suppresses_mixins_that_also_raise_a_reference
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  include FeatureFlaggingHelper\nend\n"
      write "#{root}/app/helpers/feature_flagging_helper.rb", "module FeatureFlaggingHelper; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :helpers, in: 'app/helpers/**/*.rb'
        models.cannot_use :helpers
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
      todo_path = "#{root}/archspec_todo.yml"

      assert_equal 1, diagnostics.size
      ArchSpec::Todo.write(todo_path, diagnostics, root: root)
      todo = ArchSpec::Todo.load(todo_path, root: root)

      assert_empty ArchSpec::Evaluator.evaluate(definition, graph, todo: todo)
    end
  end
end
