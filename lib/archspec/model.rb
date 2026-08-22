# frozen_string_literal: true

require 'pathname'
require 'set'

require_relative 'value_object'

module ArchSpec
  ParseError = ValueObject.define(:message, :location)
  MethodDefinition = ValueObject.define(:owner, :name, :scope, :location, :visibility)
  AssociationDeclaration = ValueObject.define(
    :owner, :name, :macro, :class_name, :through, :source, :source_type, :polymorphic, :location, :nesting
  )

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
                :nesting, :associations
    attr_accessor :superclass, :abstract

    def initialize(name:, kind:, path:, location:, nesting: [])
      @name = name
      @kind = kind
      @path = path
      @location = location
      @nesting = Array(nesting).dup.freeze
      @instance_methods = Set.new
      @class_methods = Set.new
      @method_definitions = []
      @associations = []
      @abstract = false
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

    def add_association(declaration)
      associations << declaration
    end

    def abstract?
      abstract
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
    attr_reader :name, :files, :constants, :constant_occurrences, :file_reasons, :constant_reasons

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


  # What a run could not see, counted once on the finished graph and read by
  # the formatters as it is. A constant reference that matched no definition,
  # a dynamic feature, a call on a receiver of unknown kind, a file ignored
  # by glob or unreadable by the parser: each is a blind spot with a cause,
  # so a run over code the parser barely read never prints the summary of a
  # run that read it in full.
  Census = ValueObject.define(
    :resolved_references, :unresolved_references, :unresolved_names, :dynamic_features,
    :other_receiver_calls, :ignored_files, :parse_error_files, :producers, :corrupt_cache_entries,
    :unused_suppressions, :stale_todo_entries
  ) do
    def dynamic_feature_count
      dynamic_features.values.sum { |carriers| carriers.size }
    end

    # The blind spots as prose clauses, in a fixed order, empty when the run
    # saw everything it was given.
    def clauses
      [
        clause(unresolved_references, 'unresolved constant reference'),
        clause(dynamic_feature_count, 'dynamic feature'),
        clause(other_receiver_calls, 'call with an untyped receiver', 'calls with untyped receivers'),
        clause(ignored_files, 'ignored file'),
        clause(parse_error_files, 'file with parse errors', 'files with parse errors'),
        clause(corrupt_cache_entries, 'unreadable cache entry', 'unreadable cache entries'),
        clause(unused_suppressions, 'unused suppression'),
        clause(stale_todo_entries, 'stale todo entry', 'stale todo entries')
      ].compact
    end

    def report
      {
        references: {
          resolved: resolved_references,
          unresolved: unresolved_references,
          unresolved_names: unresolved_names
        },
        dynamic_features: dynamic_features.transform_values { |carriers| { count: carriers.size, carriers: carriers } },
        other_receiver_calls: other_receiver_calls,
        ignored_files: ignored_files,
        parse_error_files: parse_error_files,
        producers: producers,
        corrupt_cache_entries: corrupt_cache_entries,
        unused_suppressions: unused_suppressions,
        stale_todo_entries: stale_todo_entries
      }
    end

    private

    def clause(count, singular, plural = "#{singular}s")
      return if count.zero?

      "#{count} #{count == 1 ? singular : plural}"
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
    EMPTY_NAMES = Set[].freeze
    EMPTY_CONSTANTS = [].freeze
    EMPTY_EDGES = [].freeze

    attr_reader :root, :files, :constants, :edges, :components, :facts_files
    attr_accessor :facts_directory, :ignored_files, :corrupt_cache_entries, :dating_note

    def initialize(root)
      @root = File.expand_path(root)
      @files = {}
      @constants = []
      @constants_by_name = Hash.new { |hash, key| hash[key] = [] }
      @edges = []
      @components = {}
      @facts_files = []
      @facts_directory = nil
      @facts_present = false
      @facts_origins = {}.compare_by_identity
      @ignored_files = []
      @corrupt_cache_entries = 0
      @census = nil
      @public_names = Hash.new { |hash, key| hash[key] = Set.new }
      @dating_note = nil
      @indexes = nil
      @effective_methods_memo = {}
    end

    # Records the names a component declares public, so a cut can name the
    # public face of a component a private reference should go through.
    def declare_public(component, names)
      @public_names[component.to_sym].merge(names.map { |name| normalize_constant(name) })
    end

    def public_names_for(component)
      @public_names[component.to_sym]
    end

    def add_file(path:, parse_errors:, suppressions: [])
      files[path] = SourceFile.new(
        root: root,
        path: path,
        parse_errors: parse_errors,
        suppressions: suppressions
      )
    end

    # Copies a constant another graph holds, or one rebuilt from a record, into
    # this graph: the node, its methods, mixins and associations, all at once,
    # so every path that restores a file agrees on what a constant carries.
    def copy_constant(held, path: held.path)
      constant = add_constant(name: held.name, kind: held.kind, path: path, location: held.location,
                              nesting: held.nesting)
      constant.superclass = held.superclass
      constant.abstract = held.abstract?
      held.method_definitions.each do |definition|
        if definition.scope == :class
          constant.add_class_method(definition.name, location: definition.location, visibility: definition.visibility)
        else
          constant.add_instance_method(definition.name, location: definition.location, visibility: definition.visibility)
        end
      end
      held.mixins.each { |kind, names| names.each { |name| constant.add_mixin(kind, name) } }
      held.associations.each { |declaration| constant.add_association(declaration) }
      constant
    end

    def add_constant(name:, kind:, path:, location:, nesting: [])
      normalized = normalize_constant(name)
      existing = @constants_by_name[normalized].find { |constant| constant.path == path && constant.kind == kind }
      return existing if existing

      constant = ConstantNode.new(name: normalized, kind: kind, path: path, location: location, nesting: nesting)
      constants << constant
      @constants_by_name[normalized] << constant
      forget_indexes
      constant
    end

    def add_edge(type:, from_path:, from_constant:, to:, location:, confidence: :high, receiver: nil,
                 lexical_nesting: nil)
      nesting = lexical_nesting&.map { |name| normalize_constant(name) }&.freeze
      edges << Edge.new(type, from_path, from_constant, to.to_s, location, confidence, receiver, nesting)
      forget_indexes
    end

    # Adds what a facts file states: each reference becomes an ordinary
    # dependency edge whose confidence names its origin, and each generated
    # method lands on the owning constant so a bare call to it counts as the
    # component's own API. A target the parser never defined stays an
    # unresolved name, exactly like a constant from a gem.
    def merge_facts(facts, only: nil)
      @facts_directory = facts.directory
      @facts_present = facts.present?

      facts.files.each do |file|
        facts_files << file

        file.references.each do |reference|
          path = File.expand_path(reference.file, root)
          next if only && !only.include?(path)

          add_edge(
            type: :references_constant,
            from_path: path,
            from_constant: normalize_constant(reference.owner),
            to: reference.target,
            location: SourceLocation.point(path, reference.line, 1),
            lexical_nesting: []
          )
          record_facts_origin(edges.last, file.relative_path)
        end

        file.generated_methods.each do |entry|
          constants_named(entry.owner).each do |constant|
            next if only && !only.include?(constant.path)

            entry.names.each { |name| constant.add_instance_method(name, location: constant.location) }
          end
        end
      end
    end

    def facts_present?
      @facts_present
    end

    def record_facts_origin(edge, relative_path)
      @facts_origins[edge] = relative_path
    end

    # Installs components as a snapshot recorded them, in place of matching
    # patterns against a tree that may no longer exist.
    def restore_components(restored)
      @components = restored.to_h { |component| [component.name, component] }
      forget_indexes
    end

    def facts_file_for(edge)
      @facts_origins[edge]
    end

    # The evidence line for an edge, naming the facts file it came from when
    # the parser did not see it.
    def edge_evidence(edge, target = edge.to)
      evidence = "#{edge_source_name(edge)} #{edge.verb} #{target}"
      origin = facts_file_for(edge)
      origin ? "#{evidence} (from #{origin})" : evidence
    end

    def constants_named(name)
      @constants_by_name[normalize_constant(name)]
    end

    def constants_for_path(path)
      indexes.fetch(:constants_by_path).fetch(path, EMPTY_CONSTANTS)
    end

    def method_definitions_for_component(name)
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

      @census = nil
      forget_indexes
    end

    def census
      @census ||= take_census
    end

    def record_housekeeping(unused_suppressions:, stale_todo_entries:)
      @census = census.with(
        unused_suppressions: unused_suppressions,
        stale_todo_entries: stale_todo_entries
      )
    end

    # The innermost constant whose definition spans the location, or nil for a
    # location outside any constant body.
    def constant_enclosing(location)
      constants_for_path(location.path).select do |constant|
        constant.location.line <= location.line && constant.location.end_line >= location.line
      end.min_by { |constant| constant.location.end_line - constant.location.line }
    end

    def dynamic_features_for(constant_name, path)
      indexes.fetch(:dynamic_features_by_path).fetch(path, EMPTY_EDGES).select do |edge|
        edge.from_constant == constant_name
      end
    end

    def component_names_for_path(path)
      indexes.fetch(:components_by_path).fetch(path, EMPTY_NAMES).dup
    end

    def component_names_for_constant(name, path: nil)
      normalized = normalize_constant(name)
      key = path ? [normalized, path] : normalized
      indexes.fetch(:components_by_constant).fetch(key, EMPTY_NAMES).dup
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
      indexes.fetch(:dependency_edges)
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
      remembered(:instance, name, visited) do
        effective_methods(name, visited) do |node|
          mixins = node.mixins[:include].to_a + node.mixins[:prepend].to_a
          [node.instance_methods, mixins.map { |ancestor| [ancestor, :instance] }, :instance]
        end
      end
    end

    # A class's methods on the class side: its own, those of every module it
    # +extend+s (their instance methods land on the singleton), and the class
    # methods of its superclass chain.
    def effective_class_methods(name, visited = Set.new)
      remembered(:class, name, visited) do
        effective_methods(name, visited) do |node|
          [node.class_methods, node.mixins[:extend].to_a.map { |ancestor| [ancestor, :instance] }, :class]
        end
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
      indexes.fetch(:constants_by_component).fetch(name.to_sym, EMPTY_CONSTANTS)
    end

    def suppressed?(diagnostic)
      suppressions_matching(diagnostic).any?
    end

    def suppressions_matching(diagnostic)
      Array(files[diagnostic.location.path]&.suppressions).select { |suppression| suppression.matches?(diagnostic) }
    end

    def suppressions
      files.values.flat_map(&:suppressions)
    end

    private

    # Built on the first query after the graph is complete and dropped by any
    # mutation, so a rule never reads a stale grouping; every shipped and
    # custom rule reads them through the query methods it already calls.
    def indexes
      @indexes ||= build_indexes
    end

    def forget_indexes
      @indexes = nil
      @effective_methods_memo.clear
    end

    def build_indexes
      by_path = Hash.new { |hash, key| hash[key] = Set.new }
      by_constant = Hash.new { |hash, key| hash[key] = Set.new }
      components.each_value do |component|
        component.files.each { |path| by_path[path].add(component.name) }
        component.constants.each { |name| by_constant[name].add(component.name) }
        component.constant_occurrences.each { |name, path| by_constant[[name, path]].add(component.name) }
      end

      by_component = Hash.new { |hash, key| hash[key] = [] }
      constants_by_path = Hash.new { |hash, key| hash[key] = [] }
      constants.each do |constant|
        constants_by_path[constant.path] << constant
        by_constant.fetch([constant.name, constant.path], EMPTY_NAMES).each do |name|
          by_component[name] << constant
        end
      end

      dynamic_by_path = Hash.new { |hash, key| hash[key] = [] }
      edges.each { |edge| dynamic_by_path[edge.from_path] << edge if edge.type == :dynamic_feature }

      {
        components_by_path: by_path,
        components_by_constant: by_constant,
        constants_by_component: by_component,
        constants_by_path: constants_by_path,
        dynamic_features_by_path: dynamic_by_path,
        dependency_edges: edges.select { |edge| DEPENDENCY_EDGE_TYPES.include?(edge.type) }
      }
    end

    # Only a top-level walk is remembered: a walk started from inside another
    # keeps the visited set it was handed, so its answer depends on the caller.
    def remembered(scope, name, visited)
      return yield unless visited.empty?

      key = [scope, normalize_constant(name)]
      methods, unresolved = @effective_methods_memo[key] ||= yield
      [methods.dup, unresolved.dup]
    end

    def take_census
      resolved = 0
      unresolved_names = Set.new
      dynamic = Hash.new { |hash, key| hash[key] = [] }
      other_receivers = 0
      producers = Hash.new(0)

      edges.each do |edge|
        case edge.type
        when *DEPENDENCY_EDGE_TYPES
          if constants_named(resolve_edge_constant(edge)).any?
            resolved += 1
          else
            unresolved_names.add(resolve_edge_constant(edge))
          end
        when :dynamic_feature
          dynamic[edge.to] << "#{edge_source_name(edge)} (#{edge.location.relative_path(root)}:#{edge.location.line})"
        when :calls_named_method
          other_receivers += 1 if edge.receiver == :other
        end
        producers[producer_of(edge)] += 1 if facts_present?
      end

      Census.new(
        resolved_references: resolved,
        unresolved_references: dependency_edges.size - resolved,
        unresolved_names: unresolved_names.to_a.sort,
        dynamic_features: dynamic.sort.to_h.transform_values(&:sort),
        other_receiver_calls: other_receivers,
        ignored_files: ignored_files.size,
        parse_error_files: files.values.count { |file| file.parse_errors.any? },
        producers: facts_present? ? producers.sort.to_h : nil,
        corrupt_cache_entries: corrupt_cache_entries,
        unused_suppressions: 0,
        stale_todo_entries: 0
      )
    end

    def producer_of(edge)
      origin = facts_file_for(edge)
      return 'parser' unless origin

      facts_files.find { |file| file.relative_path == origin }&.producer || origin
    end

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
