require "test_helper"

class RulesTest < ArchSpecTest
  def test_forbidden_dependencies_are_reported
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          UsersController
        end
      RUBY

      write "#{root}/app/controllers/users_controller.rb", <<~RUBY
        class UsersController
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: "app/models/**/*.rb"
        component :controllers, in: "app/controllers/**/*.rb"
        models.cannot_use :controllers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal "dependencies.forbid", diagnostics.first.rule
      assert_match(/models must not depend on controllers/, diagnostics.first.message)
    end
  end

  def test_allow_dependencies_reports_other_declared_components
    with_project do |root|
      write "#{root}/app/controllers/users_controller.rb", <<~RUBY
        class UsersController
          AuditLog
        end
      RUBY

      write "#{root}/app/models/user.rb", "class User; end\n"
      write "#{root}/app/jobs/audit_log.rb", "class AuditLog; end\n"

      definition = ArchSpec.define do
        component :controllers, in: "app/controllers/**/*.rb"
        component :models, in: "app/models/**/*.rb"
        component :jobs, in: "app/jobs/**/*.rb"
        controllers.can_use :models
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/controllers may not depend on jobs/, diagnostics.first.message)
    end
  end

  def test_protocol_and_method_call_rules
    with_project do |root|
      write "#{root}/app/services/good_service.rb", <<~RUBY
        class GoodService
          def call
            User
          end
        end
      RUBY

      write "#{root}/app/services/bad_service.rb", <<~RUBY
        class BadService
          def run
            render :show
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: "app/services/**/*.rb"
        services.must_implement :call
        services.cannot_call :render
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ["methods.forbid", "protocol.must_implement"], diagnostics.map(&:rule).sort
      assert diagnostics.any? { |diagnostic| diagnostic.message == "BadService must implement #call" }
      assert diagnostics.any? { |diagnostic| diagnostic.message == "services must not call #render" }
    end
  end

  def test_cycle_rule_reports_component_cycles
    with_project do |root|
      write "#{root}/app/a/alpha.rb", "class Alpha; Beta; end\n"
      write "#{root}/app/b/beta.rb", "class Beta; Alpha; end\n"

      definition = ArchSpec.define do
        source "app/**/*.rb"
        component :a, in: "app/a/**/*.rb"
        component :b, in: "app/b/**/*.rb"
        no_cycles!
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal "dependencies.no_cycles", diagnostics.first.rule
      assert_match(/a -> b -> a|b -> a -> b/, diagnostics.first.message)
    end
  end

  def test_zeitwerk_rule_reports_mismatched_file_names
    with_project do |root|
      write "#{root}/app/models/user.rb", "class Account; end\n"

      definition = ArchSpec.define do
        component :models, in: "app/models/**/*.rb"
        verify_zeitwerk_names!
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal "zeitwerk.naming", diagnostics.first.rule
      assert_match(/should define User/, diagnostics.first.message)
    end
  end

  private

  def diagnostics_for(definition, root)
    graph = ArchSpec::Analyzer.new(definition, root: root).call
    ArchSpec::Evaluator.new(definition).call(graph)
  end
end
