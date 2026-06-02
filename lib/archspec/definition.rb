module ArchSpec
  class Definition
    DEFAULT_SOURCE_PATTERNS = [
      "app/**/*.rb",
      "lib/**/*.rb",
      "packs/*/app/**/*.rb",
      "engines/*/app/**/*.rb"
    ].freeze

    DEFAULT_IGNORE_PATTERNS = [
      ".git/**/*",
      ".bundle/**/*",
      "node_modules/**/*",
      "tmp/**/*",
      "vendor/**/*"
    ].freeze

    attr_accessor :name, :root_path, :baseline_path
    attr_reader :source_patterns, :ignore_patterns, :component_specs, :rules

    def initialize(name)
      @name = name
      @root_path = "."
      @baseline_path = nil
      @source_patterns = []
      @ignore_patterns = DEFAULT_IGNORE_PATTERNS.dup
      @component_specs = {}
      @rules = []
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

    def absolute_root(base_dir = Dir.pwd)
      File.expand_path(root_path, base_dir)
    end

    def analysis_patterns
      patterns = source_patterns.empty? ? DEFAULT_SOURCE_PATTERNS.dup : source_patterns.dup
      patterns | component_specs.values.flat_map(&:file_patterns)
    end
  end
end
