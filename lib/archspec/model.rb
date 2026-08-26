# frozen_string_literal: true

require 'pathname'
require 'set'

module ArchSpec
  ParseError = Data.define(:message, :location)
  AnalysisDiagnostic = Data.define(:rule, :message, :location)
  MethodSignature = Data.define(
    :required,
    :optional,
    :rest,
    :keywords,
    :optional_keywords,
    :keyword_rest,
    :block,
    :forward
  ) do
    def accepts_arity?(arity)
      return true if forward

      maximum = rest ? Float::INFINITY : required + optional
      arity >= required && arity <= maximum
    end

    def accepts_keywords?(names)
      return true if forward

      names = names.to_set
      return false unless keywords.all? { |name| names.include?(name) }
      return true if keyword_rest

      names.all? { |name| keywords.include?(name) || optional_keywords.include?(name) }
    end

    def describe
      positional =
        if rest
          "#{required}+ positional"
        elsif optional.positive?
          "#{required}..#{required + optional} positional"
        else
          "#{required} positional"
        end
      named = (keywords.map { |name| "#{name}:" } + optional_keywords.map { |name| "#{name}:?" }).join(', ')
      [positional, ("keywords #{named}" unless named.empty?), ('**keywords' if keyword_rest), ('&block' if block),
       ('forwarding' if forward)].compact.join(', ')
    end
  end
  MethodDefinition = Data.define(:owner, :name, :scope, :location, :visibility, :signatures, :alias_target)

  Suppression = Data.define(:rule, :start_line, :end_line, :reason) do
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
    attr_accessor :superclass, :namespace_only

    def initialize(name:, kind:, path:, location:, nesting: [], namespace_only: false)
      @name = name
      @kind = kind
      @path = path
      @location = location
      @namespace_only = namespace_only
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

    def add_instance_method(name, location:, visibility: :public, signatures: [], alias_target: nil)
      instance_methods.add(name.to_sym)
      method_definitions << MethodDefinition.new(
        self.name, name.to_sym, :instance, location, visibility, signatures, alias_target
      )
    end

    def add_class_method(name, location:, visibility: :public, signatures: [], alias_target: nil)
      class_methods.add(name.to_sym)
      method_definitions << MethodDefinition.new(
        self.name, name.to_sym, :class, location, visibility, signatures, alias_target
      )
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

  Edge = Data.define(
    :type,
    :from_path,
    :from_constant,
    :to,
    :location,
    :confidence,
    :receiver,
    :lexical_nesting,
    :resolved_to,
    :resolved_receiver,
    :receiver_scope,
    :resolved_method
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

    attr_reader :root, :files, :constants, :edges, :components, :analysis_diagnostics

    def initialize(root)
      @root = File.expand_path(root)
      @files = {}
      @constants = []
      @constants_by_name = Hash.new { |hash, key| hash[key] = [] }
      @edges = []
      @components = {}
      @analysis_diagnostics = []
      @effective_definition_cache = {}
      @effective_method_cache = {}
    end

    def add_file(path:, parse_errors:, suppressions: [])
      files[path] = SourceFile.new(
        root: root,
        path: path,
        parse_errors: parse_errors,
        suppressions: suppressions
      )
    end

    def add_constant(name:, kind:, path:, location:, nesting: [], namespace_only: false)
      normalized = normalize_constant(name)
      existing = @constants_by_name[normalized].find { |constant| constant.path == path && constant.kind == kind }
      if existing
        existing.namespace_only &&= namespace_only
        return existing
      end

      constant = ConstantNode.new(name: normalized, kind: kind, path: path, location: location, nesting: nesting,
                                  namespace_only: namespace_only)
      constants << constant
      @constants_by_name[normalized] << constant
      constant
    end

    def add_edge(type:, from_path:, from_constant:, to:, location:, confidence: :high, receiver: nil,
                 lexical_nesting: nil, resolved_to: nil, resolved_receiver: nil, receiver_scope: nil,
                 resolved_method: nil)
      nesting = lexical_nesting&.map { |name| normalize_constant(name) }&.freeze
      edges << Edge.new(
        type,
        from_path,
        from_constant,
        to.to_s,
        location,
        confidence,
        receiver,
        nesting,
        resolved_to,
        resolved_receiver,
        receiver_scope,
        resolved_method
      )
    end

    def add_analysis_diagnostic(rule:, message:, location:)
      analysis_diagnostics << AnalysisDiagnostic.new(rule, message, location)
    end

    def set_namespace_only(name, path, value)
      normalized = normalize_constant(name)
      @constants_by_name[normalized].each do |constant|
        constant.namespace_only = value if constant.path == path && (constant.class? || constant.module?)
      end
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
        excluded_files = spec.exclude_patterns.each_with_object(Set.new) do |pattern, matches|
          each_matching_file(pattern) { |path| matches.add(path) }
        end

        spec.file_patterns.each do |pattern|
          each_matching_file(pattern) do |path|
            next if excluded_files.include?(path)

            files_matched_by_pattern.add(path)
            component.add_file(path, reason: "matched file pattern #{pattern}")
          end
        end

        constants.each do |constant|
          matched_file = files_matched_by_pattern.include?(constant.path) && !defers_to_real_definition?(constant)
          matched_constant = spec.matches_constant?(constant.name)
          matched_ancestor = spec.matching_ancestor(constant.name, self)
          next unless matched_file || matched_constant || matched_ancestor

          component.add_file(constant.path, reason: "defines #{constant.name}") if matched_constant || matched_ancestor
          reason =
            if matched_file
              'defined in matched file'
            elsif matched_ancestor
              "descends from #{matched_ancestor}"
            else
              'matched namespace/constant selector'
            end
          component.add_constant(constant.name, path: constant.path,
                                 reason: reason)
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
      return normalize_constant(edge.resolved_to) if edge.resolved_to

      resolve_constant_reference(edge.to, edge.from_constant, lexical_nesting: edge.lexical_nesting)
    end

    # Every resolvable ancestor in Ruby lookup order, plus names whose
    # declarations are outside the analyzed source. The scope controls whether
    # mixins come from include/prepend or extend; superclass traversal applies
    # to both sides.
    def ancestor_names(name, scope: :instance, visited: Set.new)
      normalized = normalize_constant(name)
      return [Set.new, Set.new] if visited.include?(normalized) || RESOLVED_ROOTS.include?(normalized)

      visited = visited.dup.add(normalized)
      nodes = constants_named(normalized)
      return [Set.new, Set[normalized]] if nodes.empty?

      ancestors = Set.new
      unresolved = Set.new
      nodes.each do |node|
        mixins = scope == :class ? node.mixins[:extend] : node.mixins[:prepend] | node.mixins[:include]
        mixins.each do |ancestor|
          resolved = resolve_constant_reference(ancestor, node.name, lexical_nesting: [node.name] + node.nesting)
          ancestors.add(resolved)
          nested, missing = ancestor_names(resolved, visited: visited)
          ancestors.merge(nested)
          unresolved.merge(missing)
        end

        next unless node.superclass

        resolved = resolve_constant_reference(node.superclass, node.name, lexical_nesting: node.nesting)
        ancestors.add(resolved)
        nested, missing = ancestor_names(resolved, scope: scope, visited: visited)
        ancestors.merge(nested)
        unresolved.merge(missing)
      end

      [ancestors, unresolved]
    end

    def effective_instance_methods(name)
      effective_methods(name, :instance)
    end

    def effective_class_methods(name)
      effective_methods(name, :class)
    end

    # Method definitions visible on a constant, including resolvable ancestry.
    # Extended modules contribute their instance methods to the class side.
    def effective_method_definitions(name, scope, visited = Set.new)
      normalized = normalize_constant(name)
      key = [normalized, scope]
      cached = @effective_definition_cache[key]
      return cached if visited.empty? && cached

      root = visited.empty?
      return [[], Set.new] if visited.include?(key)

      visited = visited.dup.add(key)
      return [[], Set.new] if RESOLVED_ROOTS.include?(normalized)

      nodes = constants_named(normalized)
      return [[], Set[normalized]] if nodes.empty?

      definitions = []
      visible_names = Set.new
      unresolved = Set.new

      if scope == :instance
        append_mixin_definitions(nodes, :prepend, definitions, visible_names, unresolved, visited)
      end

      own = nodes.flat_map { |node| node.method_definitions.select { |definition| definition.scope == scope } }
      append_visible_definitions(definitions, visible_names, own)

      mixin_kind = scope == :class ? :extend : :include
      append_mixin_definitions(nodes, mixin_kind, definitions, visible_names, unresolved, visited)
      append_superclass_definitions(nodes, scope, definitions, visible_names, unresolved, visited)

      result = [definitions, unresolved]
      @effective_definition_cache[key] = result if root
      result
    end

    def resolve_method_alias(owner, name, scope, visited = Set.new)
      name = name.to_sym
      return if visited.include?(name)

      definitions, = effective_method_definitions(owner, scope)
      targets = definitions.filter_map do |definition|
        definition.alias_target if definition.name == name
      end.uniq
      return unless targets.one?

      target = targets.first
      resolve_method_alias(owner, target, scope, visited.dup.add(name)) || target
    end

    def effective_methods(name, scope)
      key = [normalize_constant(name), scope]
      @effective_method_cache[key] ||= begin
        definitions, unresolved = effective_method_definitions(name, scope)
        [definitions.map(&:name).to_set, unresolved]
      end
    end

    def incoming_dependency_edges(name)
      normalized = normalize_constant(name)
      dependency_edges.select { |edge| resolve_edge_constant(edge) == normalized }
    end

    def analysis_census(path: nil)
      scoped_edges = path ? edges.select { |edge| edge.from_path == path } : edges
      scoped_diagnostics =
        if path
          analysis_diagnostics.select { |diagnostic| diagnostic.location.path == path }
        else
          analysis_diagnostics
        end
      unresolved = scoped_edges.select { |edge| DEPENDENCY_EDGE_TYPES.include?(edge.type) }.count do |edge|
        constants_named(resolve_edge_constant(edge)).empty?
      end

      {
        unresolved_constants: unresolved,
        dynamic_features: scoped_edges.count { |edge| edge.type == :dynamic_feature },
        unknown_receivers: scoped_edges.count { |edge| edge.type == :calls_named_method && edge.receiver == :other },
        rubydex_diagnostics: scoped_diagnostics.group_by(&:rule).transform_values(&:size).sort.to_h
      }
    end

    def component_assignment_reasons_for_path(path)
      components.values.each_with_object({}) do |component, reasons|
        next unless component.files.include?(path)

        reasons[component.name] = component.file_reasons[path].to_a.sort
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

    def append_mixin_definitions(nodes, kind, definitions, visible_names, unresolved, visited)
      mixins = nodes.flat_map do |node|
        node.mixins[kind].map { |ancestor| [node, ancestor] }
      end

      mixins.reverse_each do |node, ancestor|
        resolved_name = resolve_constant_reference(
          ancestor,
          node.name,
          lexical_nesting: [node.name] + node.nesting
        )
        inherited, missing = effective_method_definitions(resolved_name, :instance, visited)
        append_visible_definitions(definitions, visible_names, inherited)
        unresolved.merge(missing)
      end
    end

    def append_superclass_definitions(nodes, scope, definitions, visible_names, unresolved, visited)
      nodes.filter_map(&:superclass).uniq.each do |superclass|
        node = nodes.find { |candidate| candidate.superclass == superclass }
        resolved_name = resolve_constant_reference(superclass, node.name, lexical_nesting: node.nesting)
        inherited, missing = effective_method_definitions(resolved_name, scope, visited)
        append_visible_definitions(definitions, visible_names, inherited)
        unresolved.merge(missing)
      end
    end

    def append_visible_definitions(definitions, visible_names, candidates)
      names = candidates.map(&:name).to_set - visible_names
      definitions.concat(candidates.select { |definition| names.include?(definition.name) })
      visible_names.merge(names)
    end

    def defers_to_real_definition?(constant)
      constant.namespace_only &&
        @constants_by_name[constant.name].any? { |other| !other.namespace_only }
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
