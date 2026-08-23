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

    DEFAULT_CACHE_DIRECTORY = '.archspec/cache'
    RESOLVERS = %i[rubydex].freeze

    attr_accessor :name, :root_path, :todo_path, :facts_path, :cache_path, :base_dir, :static_associations
    SHIPPED_FORMATS = %w[text json github sarif].freeze

    attr_reader :source_patterns, :ignore_patterns, :component_specs, :rules, :registered_formatters, :resolvers

    def initialize(name = nil)
      @name = name
      @root_path = '.'
      @todo_path = nil
      @facts_path = Facts::DEFAULT_DIRECTORY
      @cache_path = nil
      @static_associations = false
      @base_dir = nil
      @source_patterns = []
      @ignore_patterns = DEFAULT_IGNORE_PATTERNS.dup
      @component_specs = {}
      @rules = []
      @registered_formatters = {}
      @resolvers = []
      @resolvers = []
    end

    def add_resolver(name)
      @resolvers |= [name.to_sym]
    end

    # Where a declared resolver keeps its index between runs: beside the parse
    # cache, under the directory the snapshot owns.
    def resolver_cache_path
      File.join(File.dirname(cache_path || DEFAULT_CACHE_DIRECTORY), 'resolvers')
    end

    def add_formatter(name, formatter)
      if SHIPPED_FORMATS.include?(name.to_s)
        raise Error, "formatter #{name.to_s.inspect} is shipped with archspec; register your own under another name"
      end

      @registered_formatters[name.to_s] = formatter
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
      merged = component_specs.fetch(spec.name)
      return if merged.except_patterns.empty? || merged.file_patterns.any?

      raise Error, "component :#{spec.name} has except: but no in: to exclude from"
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
