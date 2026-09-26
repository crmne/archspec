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

  def test_todo_file_is_stable_across_line_shifts_and_reorders
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  UsersController\n  PostsController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      write "#{root}/app/controllers/posts_controller.rb", "class PostsController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      todo_path = "#{root}/archspec_todo.yml"
      ArchSpec::Todo.write(todo_path, diagnostics_for(definition, root), root: root)
      before = File.read(todo_path)

      refute_match(/^\s*line:/, before)
      assert_equal 2, YAML.safe_load(before)['violations'].size

      write "#{root}/app/models/user.rb", "# moved\n\nclass User\n  PostsController\n  UsersController\nend\n"
      ArchSpec::Todo.write(todo_path, diagnostics_for(definition, root), root: root)

      assert_equal before, File.read(todo_path)
    end
  end

  def test_todo_reports_entries_no_diagnostic_matches_as_obsolete
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  UsersController\n  PostsController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      write "#{root}/app/controllers/posts_controller.rb", "class PostsController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      todo_path = "#{root}/archspec_todo.yml"
      ArchSpec::Todo.write(todo_path, diagnostics_for(definition, root), root: root)

      write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      todo = ArchSpec::Todo.load(todo_path, root: root)

      assert_empty ArchSpec::Evaluator.evaluate(definition, graph, todo: todo)
      obsolete = todo.unmatched_by(ArchSpec::Evaluator.unsuppressed(definition, graph))
      assert_equal 1, obsolete.size
      assert_equal 'app/models/user.rb', obsolete.first['path']
      assert_match(/PostsController/, obsolete.first['evidence'])
    end
  end

  def test_todo_with_bare_ids_still_matches_and_reports_obsolete_ids
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      id = ArchSpec::Evaluator.evaluate(definition, graph).first.fingerprint(root: root)
      todo_path = "#{root}/archspec_todo.yml"
      write todo_path, "violations:\n- #{id}\n- deadbeefdeadbeefdeadbeef\n"
      todo = ArchSpec::Todo.load(todo_path, root: root)

      assert_empty ArchSpec::Evaluator.evaluate(definition, graph, todo: todo)
      assert_equal [{ 'id' => 'deadbeefdeadbeefdeadbeef' }],
                   todo.unmatched_by(ArchSpec::Evaluator.unsuppressed(definition, graph))
    end
  end

  def test_todo_writes_one_entry_for_diagnostics_that_differ_only_by_line
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  UsersController\n  UsersController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      diagnostics = diagnostics_for(definition, root)
      assert_equal 2, diagnostics.size

      todo_path = "#{root}/archspec_todo.yml"
      count = ArchSpec::Todo.write(todo_path, diagnostics, root: root)

      assert_equal 1, count
      assert_equal 1, YAML.safe_load_file(todo_path)['violations'].size
      todo = ArchSpec::Todo.load(todo_path, root: root)
      assert_empty ArchSpec::Evaluator.evaluate(definition, ArchSpec::Analyzer.analyze(definition, root: root), todo: todo)
    end
  end

  def test_todo_treats_locally_suppressed_entries_as_obsolete
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      todo_path = "#{root}/archspec_todo.yml"
      ArchSpec::Todo.write(todo_path, diagnostics_for(definition, root), root: root)

      write "#{root}/app/models/user.rb",
            "class User\n  # archspec:disable-next-line dependencies.forbid\n  UsersController\nend\n"
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      todo = ArchSpec::Todo.load(todo_path, root: root)

      assert_equal 1, todo.unmatched_by(ArchSpec::Evaluator.unsuppressed(definition, graph)).size
    end
  end
end
