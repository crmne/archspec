# frozen_string_literal: true

require 'pathname'
require 'set'

require_relative 'value_object'

module ArchSpec
  ParseError = ValueObject.define(:message, :location)
  MethodDefinition = ValueObject.define(:owner, :name, :scope, :location)

  Suppression = ValueObject.define(:rule, :start_line, :end_line, :reason) do
    def matches?(diagnostic)
      (rule.nil? || rule == diagnostic.rule) &&
        diagnostic.location.line >= start_line &&
        diagnostic.location.line <= end_line
    end
  end

  class SourceFile
    attr_reader :path, :relative_path, :parse_errors, :suppressions

    def initialize(root:, path:, parse_errors:, suppressions:)
      @path = path
      @relative_path = Pathname(path).relative_path_from(Pathname(root)).to_s
      @parse_errors = parse_errors
      @suppressions = suppressions
    end
  end

  class ConstantNode
    attr_reader :name, :kind, :path, :location, :instance_methods, :class_methods, :method_definitions, :mixins
    attr_accessor :superclass

    def initialize(name:, kind:, path:, location:)
      @name = name
      @kind = kind
      @path = path
      @location = location
      @instance_methods = Set.new
      @class_methods = Set.new
      @method_definitions = []
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

    def add_instance_method(name, location:)
      instance_methods.add(name.to_sym)
      method_definitions << MethodDefinition.new(self.name, name.to_sym, :instance, location)
    end

    def add_class_method(name, location:)
      class_methods.add(name.to_sym)
      method_definitions << MethodDefinition.new(self.name, name.to_sym, :class, location)
    end

    def add_mixin(kind, name)
      mixins.fetch(kind).add(name)
    end
  end

  Edge = ValueObject.define(:type, :from_path, :from_constant, :to, :location, :confidence, :receiver)

  class Component
    attr_reader :name, :files, :constants, :file_reasons, :constant_reasons

    def initialize(name)
      @name = name.to_sym
      @files = Set.new
      @constants = Set.new
      @file_reasons = Hash.new { |hash, key| hash[key] = Set.new }
      @constant_reasons = Hash.new { |hash, key| hash[key] = Set.new }
    end

    def add_file(path, reason: nil)
      files.add(path)
      file_reasons[path].add(reason) if reason
    end

    def add_constant(name, reason: nil)
      constants.add(name)
      constant_reasons[name].add(reason) if reason
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

    RESOLVED_ROOTS = %w[Object BasicObject].freeze

    attr_reader :root, :files, :constants, :edges, :components

    def initialize(root)
      @root = File.expand_path(root)
      @files = {}
      @constants = []
      @constants_by_name = Hash.new { |hash, key| hash[key] = [] }
      @edges = []
      @components = {}
    end

    def add_file(path:, parse_errors:, suppressions: [])
      files[path] = SourceFile.new(
        root: root,
        path: path,
        parse_errors: parse_errors,
        suppressions: suppressions
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

    def add_edge(type:, from_path:, from_constant:, to:, location:, confidence: :high, receiver: nil)
      edges << Edge.new(type, from_path, from_constant, normalize_constant(to), location, confidence, receiver)
    end

    def constants_named(name)
      @constants_by_name[normalize_constant(name)]
    end

    def constants_for_path(path)
      constants.select { |constant| constant.path == path }
    end

    def method_definitions_for_component(name)
      component = components[name.to_sym]
      return [] unless component

      component.constants.flat_map { |constant_name| constants_named(constant_name) }.flat_map(&:method_definitions)
    end

    def assign_components(component_specs)
      @components = {}

      component_specs.each do |spec|
        component = Component.new(spec.name)

        spec.file_patterns.each do |pattern|
          each_matching_file(pattern) { |path| component.add_file(path, reason: "matched file pattern #{pattern}") }
        end

        constants.each do |constant|
          matched_file = component.files.include?(constant.path)
          matched_constant = spec.matches_constant?(constant.name)
          next unless matched_file || matched_constant

          component.add_file(constant.path, reason: "defines #{constant.name}") if matched_constant
          component.add_constant(constant.name,
                                 reason: matched_file ? 'defined in matched file' : 'matched namespace/constant selector')
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
        namespace = normalize_constant(from_constant).split('::')
        namespace.pop

        until namespace.empty?
          candidates << "#{namespace.join('::')}::#{normalized}"
          namespace.pop
        end
      end

      candidates << normalized
      candidates.find { |candidate| constants_named(candidate).any? } || normalized
    end

    # Instance methods a constant responds to, walking resolvable superclasses
    # and include/prepend mixins. Returns [methods, unresolved ancestor names];
    # a non-empty second element means the answer is incomplete.
    def effective_instance_methods(name, visited = Set.new)
      normalized = normalize_constant(name)
      return [Set.new, Set.new] if visited.include?(normalized)

      visited.add(normalized)
      return [Set.new, Set.new] if RESOLVED_ROOTS.include?(normalized)

      nodes = constants_named(normalized)
      return [Set.new, Set[normalized]] if nodes.empty?

      methods = Set.new
      unresolved = Set.new

      nodes.each do |node|
        methods.merge(node.instance_methods)

        ancestors = node.mixins[:include].to_a + node.mixins[:prepend].to_a
        ancestors << node.superclass if node.superclass

        ancestors.each do |ancestor|
          resolved_name = resolve_constant_reference(ancestor, node.name)
          ancestor_methods, ancestor_unresolved = effective_instance_methods(resolved_name, visited)
          methods.merge(ancestor_methods)
          unresolved.merge(ancestor_unresolved)
        end
      end

      [methods, unresolved]
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

    def component_assignment_reasons_for_path(path)
      components.values.each_with_object({}) do |component, reasons|
        next unless component.files.include?(path)

        reasons[component.name] = component.file_reasons[path].to_a.sort
      end
    end

    def component_assignment_reasons_for_constant(name)
      normalized = normalize_constant(name)

      components.values.each_with_object({}) do |component, reasons|
        next unless component.constants.include?(normalized)

        reasons[component.name] = component.constant_reasons[normalized].to_a.sort
      end
    end

    def suppressed?(diagnostic)
      files[diagnostic.location.path]&.suppressions&.any? { |suppression| suppression.matches?(diagnostic) }
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
      value.to_s.sub(/\A::/, '')
    end
  end
end
