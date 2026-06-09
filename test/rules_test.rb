# frozen_string_literal: true

require 'test_helper'

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
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'dependencies.forbid', diagnostics.first.rule
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
        component :controllers, in: 'app/controllers/**/*.rb'
        component :models, in: 'app/models/**/*.rb'
        component :jobs, in: 'app/jobs/**/*.rb'
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
        component :services, in: 'app/services/**/*.rb'
        services.must_implement :call
        services.cannot_call :render
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['methods.forbid', 'protocol.must_implement'], diagnostics.map(&:rule).sort
      assert(diagnostics.any? { |diagnostic| diagnostic.message == 'BadService must implement #call' })
      assert(diagnostics.any? { |diagnostic| diagnostic.message == 'services must not call #render' })
    end
  end

  def test_cycle_rule_reports_component_cycles
    with_project do |root|
      write "#{root}/app/a/alpha.rb", "class Alpha; Beta; end\n"
      write "#{root}/app/b/beta.rb", "class Beta; Alpha; end\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :a, in: 'app/a/**/*.rb'
        component :b, in: 'app/b/**/*.rb'
        no_cycles!
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'dependencies.no_cycles', diagnostics.first.rule
      assert_match(/a -> b -> a|b -> a -> b/, diagnostics.first.message)
    end
  end

  def test_zeitwerk_rule_reports_mismatched_file_names
    with_project do |root|
      write "#{root}/app/models/user.rb", "class Account; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        verify_zeitwerk_names!
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'zeitwerk.naming', diagnostics.first.rule
      assert_match(/should define User/, diagnostics.first.message)
    end
  end

  def test_disable_next_line_suppresses_one_rule
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          # archspec:disable-next-line dependencies.forbid -- migrating old controller coupling
          UsersController
          OtherController
        end
      RUBY

      write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
      write "#{root}/app/controllers/other_controller.rb", "class OtherController; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/OtherController/, diagnostics.first.evidence)
    end
  end

  def test_block_suppression_suppresses_until_enable
    with_project do |root|
      write "#{root}/app/services/create_user.rb", <<~RUBY
        class CreateUser
          # archspec:disable methods.forbid -- temporary controller API cleanup
          def call
            render :new
          end
          # archspec:enable methods.forbid

          def rollback
            redirect_to "/"
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_call :render, :redirect_to
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/redirect_to/, diagnostics.first.message)
    end
  end

  def test_parse_errors_are_reported
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def call
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
      end

      diagnostics = diagnostics_for(definition, root)

      assert(diagnostics.any? { |diagnostic| diagnostic.rule == 'parser.syntax' })
    end
  end

  def test_forbidden_method_definitions_are_reported
    with_project do |root|
      write "#{root}/app/services/create_user.rb", <<~RUBY
        class CreateUser
          def call
            User
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_define :call
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'methods.define_forbid', diagnostics.first.rule
      assert_match(/services must not define #call/, diagnostics.first.message)
      assert_match(/CreateUser defines instance method call/, diagnostics.first.evidence)
    end
  end

  def test_instantiate_and_invoke_is_reported
    with_project do |root|
      write "#{root}/app/services/create_user.rb", <<~RUBY
        class CreateUser
          def run
            UserBuilder.new(params).build
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: 'app/services/**/*.rb'
        services.cannot_instantiate_and_invoke
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'objects.instantiate_and_invoke_forbid', diagnostics.first.rule
      assert_match(/services must not instantiate and immediately invoke UserBuilder#build/, diagnostics.first.message)
    end
  end

  def test_must_be_empty_reports_every_file_in_the_component
    with_project do |root|
      write "#{root}/app/services/create_user.rb", "class CreateUser; end\n"

      definition = ArchSpec.define do
        component(:services, in: 'app/services/**/*.rb').must_be_empty(because: 'behavior belongs on models')
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['components.empty'], diagnostics.map(&:rule)
      assert_match(/services must stay empty: behavior belongs on models/, diagnostics.first.message)
    end
  end

  def test_must_be_empty_passes_when_no_files_match
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component(:services, in: 'app/services/**/*.rb').must_be_empty
      end

      assert_empty diagnostics_for(definition, root)
    end
  end
end
