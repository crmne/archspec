# frozen_string_literal: true

module ArchSpec
  # How a component selects its members: by file glob, by namespace, or by
  # explicit constant name. Created by ArchSpec::DSL::Context#component. The
  # analyzer uses it to assign files and constants to the component.
  class ComponentSpec
    attr_reader :name, :file_patterns, :exclude_patterns, :namespaces, :constants, :ancestor_names

    def initialize(name, files: [], except: [], namespace: nil, constants: nil, descendants_of: nil)
      @name = name.to_sym
      @file_patterns = Array(files).compact.map(&:to_s)
      @exclude_patterns = Array(except).compact.map(&:to_s)
      @namespaces = Array(namespace).compact.map { |value| normalize_constant(value) }
      @constants = Array(constants).compact.map { |value| normalize_constant(value) }
      @ancestor_names = Array(descendants_of).compact.map { |value| normalize_constant(value) }
    end

    def merge!(other)
      @file_patterns |= other.file_patterns
      @exclude_patterns |= other.exclude_patterns
      @namespaces |= other.namespaces
      @constants |= other.constants
      @ancestor_names |= other.ancestor_names
      self
    end

    def matches_constant?(name)
      normalized = normalize_constant(name)

      constants.include?(normalized) ||
        namespaces.any? do |namespace|
          normalized == namespace || normalized.start_with?("#{namespace}::")
        end
    end

    def matching_ancestor(name, graph)
      return if ancestor_names.empty?

      ancestors = graph.ancestor_names(name).first
      ancestor_names.find { |ancestor| ancestors.include?(ancestor) }
    end

    private

    def normalize_constant(value)
      value.to_s.sub(/\A::/, '')
    end
  end
end
