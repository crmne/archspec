# frozen_string_literal: true

require 'pathname'
require 'set'

require_relative 'value_object'

module ArchSpec
  ParseError = ValueObject.define(:message, :location)
  MethodDefinition = ValueObject.define(:owner, :name, :scope, :location, :visibility)

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
    attr_reader :name, :kind, :path, :location, :instance_methods, :class_methods, :method_definitions, :mixins,
                :nesting
    attr_accessor :superclass

    def initialize(name:, kind:, path:, location:, nesting: [])
      @name = name
      @kind = kind
      @path = path
      @location = location
      @nesting = Array(nesting).dup.freeze
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

    def add_instance_method(name, location:, visibility: :public)
      instance_methods.add(name.to_sym)
      method_definitions << MethodDefinition.new(self.name, name.to_sym, :instance, location, visibility)
    end

    def add_class_method(name, location:, visibility: :public)
      class_methods.add(name.to_sym)
      method_definitions << MethodDefinition.new(self.name, name.to_sym, :class, location, visibility)
    end

    def add_mixin(kind, name)
      mixins.fetch(kind).add(name)
    end

    # Rewrites the visibility of already-recorded definitions, for the
    # <tt>private :foo, :bar</tt> form that names methods defined earlier.
    def set_visibility(name, scope, visibility)
      name = name.to_sym
      method_definitions.map! do |definition|
        definition.name == name && definition.scope == scope ? definition.with(visibility: visibility) : definition
      end
    end
  end

  Edge = ValueObject.define(
    :type,
    :from_path,
    :from_constant,
    :to,
    :location,
    :confidence,
    :receiver,
    :lexical_nesting
  ) do
    VERBS = {
      references_constant: 'references',
      inherits_from: 'inherits from',
      includes: 'includes',
      prepends: 'prepends',
      extends: 'extends',
      calls_named_method: 'calls',
      instantiates_and_invokes: 'instantiates and invokes',
      requires: 'requires',
      requires_relative: 'requires',
      dynamic_feature: 'uses dynamic feature'
    }.freeze

    # The edge type as prose, for diagnostics and explain output.
    def verb
      VERBS.fetch(type, type.to_s.tr('_', ' '))
    end
  end

  class Component
    attr_reader :name, :files, :constants, :file_reasons, :constant_reasons

    def initialize(name)
      @name = name.to_sym
      @files = Set.new
      @constants = Set.new
      @constant_occurrences = Set.new
      @file_reasons = Hash.new { |hash, key| hash[key] = Set.new }
      @constant_reasons = Hash.new { |hash, key| hash[key] = Set.new }
    end

    def add_file(path, reason: nil)
      files.add(path)
      file_reasons[path].add(reason) if reason
    end

    def remove_file(path, reason: nil)
      files.delete(path)
      file_reasons.delete(path)
      exclusion_reasons[path].add(reason) if reason
    end

    def exclusion_reasons
      @exclusion_reasons ||= Hash.new { |hash, key| hash[key] = Set.new }
    end

    def add_constant(name, path:, reason: nil)
      constants.add(name)
      @constant_occurrences.add([name, path])
      constant_reasons[name].add(reason) if reason
    end

    def includes_constant?(name, path: nil)
      return constants.include?(name) unless path

      @constant_occurrences.include?([name, path])
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

    def add_constant(name:, kind:, path:, location:, nesting: [])
      normalized = normalize_constant(name)
      existing = @constants_by_name[normalized].find { |constant| constant.path == path && constant.kind == kind }
      return existing if existing

      constant = ConstantNode.new(name: normalized, kind: kind, path: path, location: location, nesting: nesting)
      constants << constant
      @constants_by_name[normalized] << constant
      constant
    end

    def add_edge(type:, from_path:, from_constant:, to:, location:, confidence: :high, receiver: nil,
                 lexical_nesting: nil)
      nesting = lexical_nesting&.map { |name| normalize_constant(name) }&.freeze
      edges << Edge.new(type, from_path, from_constant, to.to_s, location, confidence, receiver, nesting)
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

      constants_for_component(name).flat_map(&:method_definitions)
    end

    # Every method definition in the graph, across all constants. Used by
    # project-wide naming rules that are not scoped to one component.
    def method_definitions
      constants.flat_map(&:method_definitions)
    end

    def assign_components(component_specs)
      @components = {}

      component_specs.each do |spec|
        component = Component.new(spec.name)
        files_matched_by_pattern = Set.new

        spec.file_patterns.each do |pattern|
          each_matching_file(pattern) do |path|
            files_matched_by_pattern.add(path)
            component.add_file(path, reason: "matched file pattern #{pattern}")
          end
        end

        spec.except_patterns.each do |pattern|
          each_matching_file(pattern) do |path|
            next unless files_matched_by_pattern.delete?(path)

            component.remove_file(path, reason: "excluded by except pattern #{pattern}")
          end
        end

        constants.each do |constant|
          matched_file = files_matched_by_pattern.include?(constant.path)
          matched_constant = spec.matches_constant?(constant.name)
          next unless matched_file || matched_constant

          component.add_file(constant.path, reason: "defines #{constant.name}") if matched_constant
          component.add_constant(constant.name, path: constant.path,
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

    def component_names_for_constant(name, path: nil)
      normalized = normalize_constant(name)

      components.values.each_with_object(Set.new) do |component, names|
        names.add(component.name) if component.includes_constant?(normalized, path: path)
      end
    end

    # The edge's source as prose: its constant when known, otherwise the
    # root-relative path of the file. Diagnostics use this so evidence never
    # embeds an absolute path, which would make todo fingerprints
    # machine-specific.
    def edge_source_name(edge)
      edge.from_constant || files[edge.from_path]&.relative_path || edge.from_path
    end

    # Components that own the source of an edge. Constant and namespace
    # selectors stay precise when a file also defines unrelated constants;
    # top-level edges fall back to the file assignment.
    def source_components_for(edge)
      return component_names_for_path(edge.from_path) unless edge.from_constant

      component_names_for_constant(edge.from_constant, path: edge.from_path)
    end

    def dependency_edges
      edges.select { |edge| DEPENDENCY_EDGE_TYPES.include?(edge.type) }
    end

    def target_components_for(edge)
      return Set.new unless DEPENDENCY_EDGE_TYPES.include?(edge.type)

      resolved = resolve_edge_constant(edge)
      constants_named(resolved).each_with_object(Set.new) do |constant, names|
        names.merge(component_names_for_constant(resolved, path: constant.path))
      end
    end

    def resolve_constant_reference(name, from_constant = nil, lexical_nesting: nil)
      absolute = name.to_s.start_with?('::')
      normalized = normalize_constant(name)
      return normalized if absolute

      scopes = lexical_nesting || inferred_nesting(from_constant)
      candidates = scopes.map { |scope| "#{normalize_constant(scope)}::#{normalized}" }
      candidates << normalized
      candidates.find { |candidate| constants_named(candidate).any? } || normalized
    end

    # Resolves an edge with the lexical nesting captured where the reference
    # appeared. This matters for compact class declarations and superclass
    # expressions, where inferring scope from the finished class name is wrong.
    def resolve_edge_constant(edge)
      resolve_constant_reference(edge.to, edge.from_constant, lexical_nesting: edge.lexical_nesting)
    end

    # Instance methods a constant responds to, walking resolvable superclasses
    # and include/prepend mixins. Returns [methods, unresolved ancestor names];
    # a non-empty second element means the answer is incomplete.
    def effective_instance_methods(name, visited = Set.new)
      effective_methods(name, visited) do |node|
        mixins = node.mixins[:include].to_a + node.mixins[:prepend].to_a
        [node.instance_methods, mixins.map { |ancestor| [ancestor, :instance] }, :instance]
      end
    end

    # A class's methods on the class side: its own, those of every module it
    # +extend+s (their instance methods land on the singleton), and the class
    # methods of its superclass chain.
    def effective_class_methods(name, visited = Set.new)
      effective_methods(name, visited) do |node|
        [node.class_methods, node.mixins[:extend].to_a.map { |ancestor| [ancestor, :instance] }, :class]
      end
    end

    def effective_methods_in_scope(name, scope)
      scope == :class ? effective_class_methods(name) : effective_instance_methods(name)
    end

    def component_assignment_reasons_for_path(path)
      components.values.each_with_object({}) do |component, reasons|
        next unless component.files.include?(path)

        reasons[component.name] = component.file_reasons[path].to_a.sort
      end
    end

    def component_exclusion_reasons_for_path(path)
      components.values.each_with_object({}) do |component, reasons|
        next unless component.exclusion_reasons.key?(path)
        next if component.files.include?(path)

        reasons[component.name] = component.exclusion_reasons[path].to_a.sort
      end
    end

    def component_assignment_reasons_for_constant(name, path: nil)
      normalized = normalize_constant(name)

      components.values.each_with_object({}) do |component, reasons|
        next unless component.includes_constant?(normalized, path: path)

        reasons[component.name] = component.constant_reasons[normalized].to_a.sort
      end
    end

    def constants_for_component(name)
      component = components[name.to_sym]
      return [] unless component

      constants.select { |constant| component.includes_constant?(constant.name, path: constant.path) }
    end

    def suppressed?(diagnostic)
      files[diagnostic.location.path]&.suppressions&.any? { |suppression| suppression.matches?(diagnostic) }
    end

    private

    # Walks a constant's ancestry collecting methods. The block maps a node to
    # its own methods in the requested scope, the mixins to follow with the
    # scope to read them in, and the scope to read the superclass chain in.
    # Superclass resolution and the cycle guard are shared by both walks.
    def effective_methods(name, visited, &)
      normalized = normalize_constant(name)
      return [Set.new, Set.new] if visited.include?(normalized)

      visited.add(normalized)
      return [Set.new, Set.new] if RESOLVED_ROOTS.include?(normalized)

      nodes = constants_named(normalized)
      return [Set.new, Set[normalized]] if nodes.empty?

      methods = Set.new
      unresolved = Set.new

      nodes.each do |node|
        own_methods, mixins, superclass_scope = yield(node)
        methods.merge(own_methods)

        mixins.each do |ancestor, scope|
          resolved_name = resolve_constant_reference(
            ancestor,
            node.name,
            lexical_nesting: [node.name] + node.nesting
          )
          ancestor_methods, ancestor_unresolved = walk_ancestor(resolved_name, scope, visited, &)
          methods.merge(ancestor_methods)
          unresolved.merge(ancestor_unresolved)
        end

        if node.superclass
          resolved_name = resolve_constant_reference(node.superclass, node.name, lexical_nesting: node.nesting)
          ancestor_methods, ancestor_unresolved = walk_ancestor(resolved_name, superclass_scope, visited, &)
          methods.merge(ancestor_methods)
          unresolved.merge(ancestor_unresolved)
        end
      end

      [methods, unresolved]
    end

    def walk_ancestor(name, scope, visited, &)
      if scope == :instance
        effective_instance_methods(name, visited)
      else
        effective_methods(name, visited, &)
      end
    end

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

    def inferred_nesting(from_constant)
      return [] unless from_constant

      parts = normalize_constant(from_constant).split('::')
      parts.length.downto(1).map { |length| parts.first(length).join('::') }
    end
  end
end
