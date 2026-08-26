# frozen_string_literal: true

require 'test_helper'

class NamingRulesTest < ArchSpecTest
  def test_forbidden_flags_matching_public_methods
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def get_name; @name; end
          def name; @name; end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/\A(get|set)_/).forbidden(because: 'use plain names')
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'naming.forbidden', diagnostics.first.rule
      assert_equal 'User must not define #get_name', diagnostics.first.message
      assert_equal 'use plain names', diagnostics.first.reason
      assert_equal :high, diagnostics.first.confidence
    end
  end

  def test_forbidden_respects_except
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          def is_admin; end
          def is_owner; end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/\Ais_/).forbidden(except: [:is_admin])
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/User must not define #is_owner/, diagnostics.first.message)
    end
  end

  def test_forbidden_is_public_only_across_visibility_forms
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User
          private def get_inline; end

          private

          def get_bare; end

          public

          def get_named; end
          private :get_named
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/\Aget_/).forbidden
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_requires_flags_missing_sibling_in_same_component
    with_project do |root|
      write "#{root}/app/models/chat.rb", <<~RUBY
        class Chat
          def with_model(m); self; end
          def with_temperature(t); self; end
          def without_temperature; self; end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/\Awith_(?<base>.+)/).requires('without_%{base}')
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'naming.requires', diagnostics.first.rule
      assert_equal 'Chat#with_model requires a matching #without_model', diagnostics.first.message
    end
  end

  def test_requires_passes_when_every_sibling_exists
    with_project do |root|
      write "#{root}/app/models/chat.rb", <<~RUBY
        class Chat
          def with_model(m); self; end
          def without_model; self; end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/\Awith_(?<base>.+)/).requires('without_%{base}')
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_requires_bang_method_needs_plain_sibling
    with_project do |root|
      write "#{root}/app/models/account.rb", <<~RUBY
        class Account
          def save!; end
          def refresh!; end
          def save; end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/(?<base>.+)!\z/).requires('%{base}')
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/Account#refresh! requires a matching #refresh/, diagnostics.first.message)
    end
  end

  def test_requires_across_components_at_class_scope
    with_project do |root|
      write "#{root}/app/chat/chat.rb", <<~RUBY
        class Chat
          def with_model(m); self; end
          def with_temperature(t); self; end
        end
      RUBY

      write "#{root}/app/agent/agent.rb", <<~RUBY
        class Agent
          def self.temperature; end
        end
      RUBY

      definition = ArchSpec.define do
        source 'app/**/*.rb'
        component :chat, in: 'app/chat/**/*.rb'
        component :agent, in: 'app/agent/**/*.rb'
        chat.method_names.matching(/\Awith_(?<b>.+)/).requires('%{b}', on: agent, scope: :class)
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'Chat#with_model requires agent to define #model', diagnostics.first.message
    end
  end

  def test_private_singleton_method_does_not_trip_instance_rule
    with_project do |root|
      write "#{root}/app/models/agent.rb", <<~RUBY
        class Agent
          class << self
            def create
              with_rails_chat_record
            end

            private

            def with_rails_chat_record; end
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/\Awith_/).forbidden
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_class_scoped_rule_catches_public_singleton_method
    with_project do |root|
      write "#{root}/app/models/agent.rb", <<~RUBY
        class Agent
          class << self
            def get_config; end
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names(scope: :class).matching(/\Aget_/).forbidden
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/Agent must not define #get_config/, diagnostics.first.message)
    end
  end

  def test_scope_class_selects_class_methods
    with_project do |root|
      write "#{root}/app/models/report.rb", <<~RUBY
        class Report
          def self.get_totals; end
          def get_row; end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names(scope: :class).matching(/\Aget_/).forbidden
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_match(/Report must not define #get_totals/, diagnostics.first.message)
    end
  end

  def test_naming_rules_reject_invalid_selectors_and_scopes
    scope_error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names(scope: :singleton).matching(/.*/).forbidden
      end
    end
    selector_error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching('get_').forbidden
      end
    end
    required_scope_error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/.*/).requires('required', scope: :singleton)
      end
    end

    assert_match(/scope: must be :instance or :class/, scope_error.message)
    assert_match(/expects a Regexp/, selector_error.message)
    assert_match(/requires scope:/, required_scope_error.message)
  end

  def test_requires_rejects_an_unknown_target_component
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/.*/).requires('required', on: :modelz)
      end
    end

    assert_match(/references unknown component: modelz/, error.message)
  end

  def test_requires_rejects_unknown_capture_names
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        models.method_names.matching(/\Awith_(?<base>.+)/).requires('without_%{typo}')
      end
    end

    assert_match(/invalid requires template.*typo/, error.message)
  end
end
