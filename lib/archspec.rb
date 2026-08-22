# frozen_string_literal: true

require_relative 'archspec/error'
require_relative 'archspec/version'
require_relative 'archspec/value_object'
require_relative 'archspec/source_location'
require_relative 'archspec/diagnostic'
require_relative 'archspec/cut'
require_relative 'archspec/line_age'
require_relative 'archspec/component_spec'
require_relative 'archspec/model'
require_relative 'archspec/definition'
require_relative 'archspec/todo'
require_relative 'archspec/facts'
require_relative 'archspec/snapshot'
require_relative 'archspec/delta'
require_relative 'archspec/explanation'
require_relative 'archspec/dsl'
require_relative 'archspec/parse_cache'
require_relative 'archspec/analyzer'
require_relative 'archspec/evaluator'
require_relative 'archspec/architectures'
require_relative 'archspec/rules/annotated'
require_relative 'archspec/rules/component_rules'
require_relative 'archspec/rules/concern_rules'
require_relative 'archspec/rules/dependency_rules'
require_relative 'archspec/rules/naming_rules'
require_relative 'archspec/rules/privacy_rule'
require_relative 'archspec/rules/protocol_rules'
require_relative 'archspec/rules/cycle_rule'
require_relative 'archspec/formatters/style'
require_relative 'archspec/formatters/text'
require_relative 'archspec/formatters/json'
require_relative 'archspec/formatters/github'
require_relative 'archspec/formatters/sarif'
require_relative 'archspec/formatters/explanation'
require_relative 'archspec/formatters/explanation_json'
require_relative 'archspec/reflect'
require_relative 'archspec/associations'
require_relative 'archspec/rubydex'
require_relative 'archspec/cli'

# ArchSpec turns your application's architecture into executable checks.
#
# You describe components, dependencies, and boundaries in an +Archspec.rb+
# file written in the ArchSpec::DSL, then run <tt>archspec check</tt> to verify
# every change. ArchSpec reads Ruby source with Prism and never boots the app.
#
# The DSL is the public API. An +Archspec.rb+ file is evaluated directly:
#
#   architecture :rails
#
#   component :services, in: "app/services/**/*.rb"
#   services.cannot_call :render, :redirect_to, receiver: :none
#
# See ArchSpec::DSL::Context for the top-level DSL and
# ArchSpec::DSL::ComponentProxy for per-component rules. See
# ArchSpec::Architectures for the bundled architecture presets.
#
# You can also build a definition in plain Ruby with ArchSpec.define.
module ArchSpec
  class << self
    # Builds an architecture definition from a block of DSL calls.
    #
    #   ArchSpec.define do
    #     component :models, in: "app/models/**/*.rb"
    #     component :controllers, in: "app/controllers/**/*.rb"
    #     models.cannot_use :controllers
    #   end
    #
    # An +Archspec.rb+ file is not written with this wrapper. Its top level is
    # already the DSL, so bare +component+ and +architecture+ calls work
    # directly. Use +define+ when constructing a definition from Ruby, such as
    # in a test.
    #
    # Returns the ArchSpec::Definition.
    def define(name = nil, &block)
      definition = Definition.new(name)
      definition.extend(DSL::Context)
      definition.instance_eval(&block) if block
      definition
    end
  end
end
