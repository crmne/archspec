require_relative "archspec/version"
require_relative "archspec/source_location"
require_relative "archspec/diagnostic"
require_relative "archspec/component_spec"
require_relative "archspec/model"
require_relative "archspec/definition"
require_relative "archspec/baseline"
require_relative "archspec/dsl"
require_relative "archspec/analyzer"
require_relative "archspec/evaluator"
require_relative "archspec/presets"
require_relative "archspec/rules/dependency_rules"
require_relative "archspec/rules/protocol_rules"
require_relative "archspec/rules/cycle_rule"
require_relative "archspec/rules/zeitwerk_rule"
require_relative "archspec/formatters/text"
require_relative "archspec/formatters/json"
require_relative "archspec/cli"

module ArchSpec
  class Error < StandardError; end

  class << self
    attr_accessor :last_definition

    def define(name = "Architecture", &block)
      self.last_definition = Definition.build(name, &block)
    end
  end
end
