# frozen_string_literal: true

module ArchSpec
  # How a component selects its members: by file glob, by namespace, or by
  # explicit constant name. Created by ArchSpec::DSL::Context#component. The
  # analyzer uses it to assign files and constants to the component.
  class ComponentSpec
    attr_reader :name, :file_patterns, :namespaces, :constants

    def initialize(name, files: [], namespace: nil, constants: nil)
      @name = name.to_sym
      @file_patterns = Array(files).compact.map(&:to_s)
      @namespaces = Array(namespace).compact.map { |value| normalize_constant(value) }
      @constants = Array(constants).compact.map { |value| normalize_constant(value) }
    end

    def merge!(other)
      @file_patterns |= other.file_patterns
      @namespaces |= other.namespaces
      @constants |= other.constants
      self
    end

    def matches_constant?(name)
      normalized = normalize_constant(name)

      constants.include?(normalized) ||
        namespaces.any? do |namespace|
          normalized == namespace || normalized.start_with?("#{namespace}::")
        end
    end

    private

    def normalize_constant(value)
      value.to_s.sub(/\A::/, '')
    end
  end
end
