require "test_helper"

class BaselineTest < ArchSpecTest
  def test_baseline_uses_root_relative_fingerprints
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; UsersController; end\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"

      definition = ArchSpec.define do
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers
      end

      graph = ArchSpec::Analyzer.new(definition, root: root).analyze
      diagnostics = ArchSpec::Evaluator.new(definition).evaluate(graph)
      baseline_path = "#{root}/.archspec_todo.yml"

      ArchSpec::Baseline.write(baseline_path, diagnostics, root: root)
      baseline = ArchSpec::Baseline.load(baseline_path, root: root)

      assert_empty ArchSpec::Evaluator.new(definition, baseline: baseline).evaluate(graph)
      assert_match "app/models/user.rb", File.read(baseline_path)
      refute_match root, File.read(baseline_path)
    end
  end
end
