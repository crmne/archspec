# frozen_string_literal: true

module ArchSpec
  # The result of evaluating an +Archspec.rb+ file: the project settings,
  # declared components, and rules. ArchSpec::DSL::Context is mixed into an
  # instance to provide the DSL, and the analyzer and evaluator read it to run
  # the checks. Build one with ArchSpec.define.
  class Definition
    DEFAULT_SOURCE_PATTERNS = [
      'app/**/*.rb',
      'lib/**/*.rb',
      'packs/*/app/**/*.rb',
      'engines/*/app/**/*.rb'
    ].freeze

    DEFAULT_IGNORE_PATTERNS = [
      '.git/**/*',
      '.bundle/**/*',
      'node_modules/**/*',
      'tmp/**/*',
      'vendor/**/*'
    ].freeze

    attr_accessor :name, :root_path, :todo_path, :base_dir
    attr_reader :source_patterns, :ignore_patterns, :component_specs, :rules, :inflections

    def initialize(name = nil)
      @name = name
      @root_path = '.'
      @todo_path = nil
      @base_dir = nil
      @source_patterns = []
      @ignore_patterns = DEFAULT_IGNORE_PATTERNS.dup
      @component_specs = {}
      @rules = []
      @inflections = {}
    end

    def add_inflections(map)
      @inflections.merge!(map.to_h.transform_keys(&:to_s).transform_values(&:to_s))
    end

    def add_source_patterns(patterns)
      @source_patterns |= Array(patterns).flatten.compact.map(&:to_s)
    end

    def add_ignore_patterns(patterns)
      @ignore_patterns |= Array(patterns).flatten.compact.map(&:to_s)
    end

    def add_component(spec)
      if component_specs.key?(spec.name)
        component_specs.fetch(spec.name).merge!(spec)
      else
        component_specs[spec.name] = spec
      end
    end

    def component?(name)
      component_specs.key?(name.to_sym)
    end

    def add_rule(rule)
      rules << rule
    end

    # The directory file patterns resolve against: root_path expanded from the
    # directory the Archspec.rb was loaded from (base_dir), or the working
    # directory when built without a file.
    def absolute_root(base = base_dir || Dir.pwd)
      File.expand_path(root_path, base)
    end

    def analysis_patterns
      patterns = source_patterns.empty? ? DEFAULT_SOURCE_PATTERNS.dup : source_patterns.dup
      patterns | component_specs.values.flat_map(&:file_patterns)
    end
  end
end
