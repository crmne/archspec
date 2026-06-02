require "pathname"
require "set"

module ArchSpec
  class SourceFile
    attr_reader :path, :relative_path, :expected_constant, :parse_errors

    def initialize(root:, path:, expected_constant:, parse_errors:)
      @path = path
      @relative_path = Pathname(path).relative_path_from(Pathname(root)).to_s
      @expected_constant = expected_constant
      @parse_errors = parse_errors
    end
  end

  class ConstantNode
    attr_reader :name, :kind, :path, :location, :instance_methods, :class_methods, :mixins
    attr_accessor :superclass

    def initialize(name:, kind:, path:, location:)
      @name = name
      @kind = kind
      @path = path
      @location = location
      @instance_methods = Set.new
      @class_methods = Set.new
      @mixins = {
        include: Set.new,
        prepend: Set.new,
        extend: Set.new
      }
    end

    def class?
      kind == :class
    end

    def module?
      kind == :module
    end

    def add_instance_method(name)
      instance_methods.add(name.to_sym)
    end

    def add_class_method(name)
      class_methods.add(name.to_sym)
    end

    def add_mixin(kind, name)
      mixins.fetch(kind).add(name)
    end
  end

  Edge = Data.define(:type, :from_path, :from_constant, :to, :location, :confidence)

  class Component
    attr_reader :name, :files, :constants

    def initialize(name)
      @name = name.to_sym
      @files = Set.new
      @constants = Set.new
    end

    def add_file(path)
      files.add(path)
    end

    def add_constant(name)
      constants.add(name)
    end
  end

  class Graph
    DEPENDENCY_EDGE_TYPES = %i[
      references_constant
      inherits_from
      includes
      prepends
      extends
    ].freeze

    attr_reader :root, :files, :constants, :edges, :components

    def initialize(root)
      @root = File.expand_path(root)
      @files = {}
      @constants = []
      @constants_by_name = Hash.new { |hash, key| hash[key] = [] }
      @edges = []
      @components = {}
    end

    def add_file(path:, expected_constant:, parse_errors:)
      files[path] = SourceFile.new(
        root: root,
        path: path,
        expected_constant: expected_constant,
        parse_errors: parse_errors
      )
    end

    def add_constant(name:, kind:, path:, location:)
      normalized = normalize_constant(name)
      existing = @constants_by_name[normalized].find { |constant| constant.path == path && constant.kind == kind }
      return existing if existing

      constant = ConstantNode.new(name: normalized, kind: kind, path: path, location: location)
      constants << constant
      @constants_by_name[normalized] << constant
      constant
    end

    def add_edge(type:, from_path:, from_constant:, to:, location:, confidence: :high)
      edges << Edge.new(type, from_path, from_constant, normalize_constant(to), location, confidence)
    end

    def constants_named(name)
      @constants_by_name[normalize_constant(name)]
    end

    def constants_for_path(path)
      constants.select { |constant| constant.path == path }
    end

    def assign_components(component_specs)
      @components = {}

      component_specs.each do |spec|
        component = Component.new(spec.name)

        spec.file_patterns.each do |pattern|
          each_matching_file(pattern) { |path| component.add_file(path) }
        end

        constants.each do |constant|
          next unless component.files.include?(constant.path) || spec.matches_constant?(constant.name)

          component.add_file(constant.path)
          component.add_constant(constant.name)
        end

        @components[component.name] = component
      end
    end

    def component_names_for_path(path)
      components.values.each_with_object(Set.new) do |component, names|
        names.add(component.name) if component.files.include?(path)
      end
    end

    def component_names_for_constant(name)
      normalized = normalize_constant(name)

      components.values.each_with_object(Set.new) do |component, names|
        names.add(component.name) if component.constants.include?(normalized)
      end
    end

    def dependency_edges
      edges.select { |edge| DEPENDENCY_EDGE_TYPES.include?(edge.type) }
    end

    def target_components_for(edge)
      return Set.new unless DEPENDENCY_EDGE_TYPES.include?(edge.type)

      resolved = resolve_constant_reference(edge.to, edge.from_constant)
      constants_named(resolved).each_with_object(Set.new) do |constant, names|
        names.merge(component_names_for_path(constant.path))
        names.merge(component_names_for_constant(constant.name))
      end
    end

    def resolve_constant_reference(name, from_constant)
      normalized = normalize_constant(name)
      candidates = []

      if from_constant
        namespace = normalize_constant(from_constant).split("::")
        namespace.pop

        until namespace.empty?
          candidates << "#{namespace.join("::")}::#{normalized}"
          namespace.pop
        end
      end

      candidates << normalized
      candidates.find { |candidate| constants_named(candidate).any? } || normalized
    end

    def component_dependency_pairs(only: nil)
      allowed_sources = Array(only).compact.map(&:to_sym).to_set
      pairs = Set.new

      dependency_edges.each do |edge|
        source_components = component_names_for_path(edge.from_path)
        source_components &= allowed_sources unless allowed_sources.empty?
        next if source_components.empty?

        target_components_for(edge).each do |target|
          source_components.each do |source|
            pairs.add([source, target]) unless source == target
          end
        end
      end

      pairs
    end

    private

    def each_matching_file(pattern)
      glob = File.absolute_path(pattern, root)
      Dir.glob(glob).sort.each do |path|
        expanded = File.expand_path(path)
        yield expanded if files.key?(expanded)
      end
    end

    def normalize_constant(value)
      value.to_s.sub(/\A::/, "")
    end
  end
end
