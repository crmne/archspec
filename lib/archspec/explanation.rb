# frozen_string_literal: true

require 'pathname'

require_relative 'error'
require_relative 'model'
require_relative 'value_object'

module ArchSpec
  # Everything ArchSpec can say about one subject, a file, a constant or a
  # component, gathered once from a graph and the diagnostics the rules
  # produced over it. The formatters print it and compute nothing; the CLI
  # builds it, from a snapshot when one is comparable with the tree and from
  # a fresh analysis otherwise, and says which in the origin.
  #
  # The blast radius is the one question that needs the rules again: the
  # subject's files are taken out of every component, each rule is evaluated
  # once more over that graph, and the two diagnostic sets are compared by
  # fingerprint. The block handed to .build runs a rule over a graph; the
  # explanation never reaches the evaluator itself.
  class Explanation
    Origin = ValueObject.define(:source, :commit, :dirty, :cause) do
      def snapshot?
        source == :snapshot
      end

      def to_h
        { source: source.to_s, commit: commit, dirty: dirty, cause: cause }
      end
    end

    IncomingEdge = ValueObject.define(:kind, :from, :path, :line, :column, :components, :target)
    OutgoingEdge = ValueObject.define(:kind, :target, :line, :column, :producer, :determination)
    AncestryLink = ValueObject.define(:kind, :name, :resolved, :resolution, :depth, :origin)
    RuleOutcome = ValueObject.define(:id, :reason, :diagnostics)
    BlastRadius = ValueObject.define(:appearing, :vanishing, :not_computed)

    SUPERCLASS_KIND = :superclass

    attr_reader :origin, :kind, :name, :path, :root, :defined_constants, :parse_errors, :components, :exclusions,
                :suppressions, :incoming, :outgoing, :census, :rules, :diagnostics, :blast_radius, :constants,
                :members, :public_face, :fan_in, :fan_out

    def self.build(graph:, rules:, diagnostics:, todo:, subject:, origin:, &evaluate)
      new(graph, rules, diagnostics, todo, subject, origin, &evaluate)
    end

    def initialize(graph, rules, diagnostics, todo, subject, origin, &evaluate)
      @graph = graph
      @all_rules = rules
      @all_diagnostics = diagnostics
      @todo = todo
      @origin = origin
      @root = graph.root
      resolve_subject(subject, &evaluate)
    end

    def file?
      kind == :file
    end

    def constant?
      kind == :constant
    end

    def component?
      kind == :component
    end

    def to_h
      document = { origin: origin.to_h, subject: { kind: kind.to_s, name: name, path: path && relative(path) } }
      document.merge!(file_document) if file?
      document.merge!(constant_document) if constant?
      document.merge!(component_document) if component?
      document
    end

    private

    attr_reader :graph

    def resolve_subject(subject, &evaluate)
      absolute = File.expand_path(subject, root)
      if graph.files.key?(absolute)
        explain_file(absolute, &evaluate)
      elsif graph.constants_named(subject).any?
        explain_constant(subject, &evaluate)
      elsif graph.components.key?(subject.to_sym)
        explain_component(subject.to_sym)
      else
        raise Error, "no file, constant or component found for #{subject.inspect}"
      end
    end

    def explain_file(absolute, &evaluate)
      @kind = :file
      @path = absolute
      @name = relative(absolute)
      file = graph.files.fetch(absolute)
      nodes = graph.constants_for_path(absolute)
      @defined_constants = nodes.map(&:name)
      @parse_errors = file.parse_errors
      @suppressions = file.suppressions
      @components = graph.component_assignment_reasons_for_path(absolute)
      @exclusions = graph.component_exclusion_reasons_for_path(absolute)
      names = nodes.map(&:name).to_set
      @incoming = incoming_edges(names)
      @outgoing = outgoing_edges { |edge| edge.from_path == absolute }
      @census = census_for(absolute)
      @rules = rules_naming(graph.component_names_for_path(absolute))
      @diagnostics = @all_diagnostics.select { |diagnostic| diagnostic.location.path == absolute }
      @blast_radius = blast_radius_for([absolute], &evaluate)
    end

    def explain_constant(subject, &evaluate)
      @kind = :constant
      nodes = graph.constants_named(subject)
      @name = nodes.first.name
      @path = nil
      paths = nodes.map(&:path).uniq
      @constants = nodes.map { |node| constant_entry(node) }
      @incoming = incoming_edges(Set[@name])
      @outgoing = outgoing_edges { |edge| edge.from_constant == @name }
      @census = census_for(*paths)
      @rules = rules_naming(nodes.flat_map { |node| graph.component_names_for_constant(node.name, path: node.path).to_a })
      @diagnostics = @all_diagnostics.select { |diagnostic| graph.constant_enclosing(diagnostic.location)&.name == @name }
      @blast_radius = blast_radius_for(paths, &evaluate)
    end

    def explain_component(component_name)
      @kind = :component
      @name = component_name.to_s
      @path = nil
      component = graph.components.fetch(component_name)
      @members = {
        files: component.files.map { |file| relative(file) }.sort,
        constants: component.constants.to_a.sort
      }
      @public_face = public_face_for(component_name)
      @fan_in, @fan_out = fans_for(component_name)
      @rules = rules_naming([component_name])
      @diagnostics = @all_diagnostics.select { |diagnostic| component.files.include?(diagnostic.location.path) }
    end

    def constant_entry(node)
      {
        name: node.name,
        kind: node.kind,
        path: relative(node.path),
        line: node.location.line,
        components: graph.component_assignment_reasons_for_constant(node.name, path: node.path),
        superclass: node.superclass,
        instance_methods: node.instance_methods.to_a.sort,
        class_methods: node.class_methods.to_a.sort,
        ancestry: ancestry_of(node)
      }
    end

    # Every link in the resolved ancestry, depth first, each naming how the
    # graph resolved it. An ancestor the graph does not define ends its branch
    # and is named as unresolved rather than skipped.
    def ancestry_of(node, visited = Set.new, depth = 1)
      visited.add(node.name)
      links = []
      each_ancestor_of(node) do |link_kind, declared, lexical_nesting|
        resolved = graph.resolve_constant_reference(declared, node.name, lexical_nesting: lexical_nesting)
        targets = graph.constants_named(resolved)
        links << AncestryLink.new(
          kind: link_kind,
          name: declared,
          resolved: resolved,
          resolution: targets.any? ? :lexical : :unresolved,
          depth: depth,
          origin: ancestry_origin(node, link_kind, declared)
        )
        next if targets.empty? || visited.include?(resolved) || Graph::RESOLVED_ROOTS.include?(resolved)

        targets.each { |target| links.concat(ancestry_of(target, visited, depth + 1)) }
      end
      links
    end

    def each_ancestor_of(node)
      yield SUPERCLASS_KIND, node.superclass, node.nesting if node.superclass
      %i[include prepend extend].each do |mixin_kind|
        node.mixins.fetch(mixin_kind, []).to_a.sort.each do |declared|
          yield mixin_kind, declared, [node.name] + node.nesting
        end
      end
    end

    def ancestry_origin(node, link_kind, declared)
      type = link_kind == SUPERCLASS_KIND ? :inherits_from : :"#{link_kind}s"
      edge = graph.edges.find do |candidate|
        candidate.from_constant == node.name && candidate.type == type && candidate.to == declared
      end
      edge ? producer_of(edge) : 'parser'
    end

    def incoming_edges(names)
      return [] if names.empty?

      graph.dependency_edges.filter_map do |edge|
        resolved = graph.resolve_edge_constant(edge)
        next unless names.include?(resolved)

        IncomingEdge.new(
          kind: edge.verb,
          from: graph.edge_source_name(edge),
          path: edge.location.relative_path(root),
          line: edge.location.line,
          column: edge.location.column,
          components: graph.source_components_for(edge).map(&:to_s).sort,
          target: resolved
        )
      end.sort_by { |edge| [edge.path, edge.line, edge.column, edge.kind] }
    end

    def outgoing_edges
      graph.edges.select { |edge| yield(edge) }.map do |edge|
        OutgoingEdge.new(
          kind: edge.verb,
          target: edge.to,
          line: edge.location.line,
          column: edge.location.column,
          producer: producer_of(edge),
          determination: determination_of(edge)
        )
      end
    end

    def determination_of(edge)
      return unless Graph::DEPENDENCY_EDGE_TYPES.include?(edge.type)
      return :facts if graph.facts_file_for(edge)

      resolution = graph.resolve_edge(edge)
      return :"#{resolution.name} via #{resolution.ancestor}" if resolution.determination == :ancestry

      resolution.determination
    end

    def producer_of(edge)
      origin = graph.facts_file_for(edge)
      return 'parser' unless origin

      graph.facts_files.find { |file| file.relative_path == origin }&.producer || origin
    end

    def census_for(*paths)
      unresolved = Set.new
      unknown_receivers = 0
      graph.edges.each do |edge|
        next unless paths.include?(edge.from_path)

        if Graph::DEPENDENCY_EDGE_TYPES.include?(edge.type)
          resolved = graph.resolve_edge_constant(edge)
          unresolved.add(resolved) if graph.constants_named(resolved).empty?
        elsif edge.type == :calls_named_method && edge.receiver == :other
          unknown_receivers += 1
        end
      end
      dynamic = paths.flat_map { |file| graph.dynamic_features_for(nil, file) }.map do |edge|
        { feature: edge.to, line: edge.location.line, constant: edge.from_constant }
      end
      {
        unresolved_references: unresolved.to_a.sort,
        dynamic_features: dynamic.sort_by { |entry| [entry[:line], entry[:feature]] },
        unknown_receiver_calls: unknown_receivers
      }
    end

    # The rules that name any of the components, through whichever role the
    # rule gives them. A rule that keeps no component list, such as a custom
    # object or a no_cycles over every component, names all of them.
    def rules_naming(component_names)
      wanted = component_names.map(&:to_sym).to_set
      return [] if wanted.empty?

      @all_rules.filter_map do |rule|
        next unless rule.respond_to?(:id)

        named = components_of(rule)
        next unless named.nil? || named.intersect?(wanted)

        RuleOutcome.new(
          id: rule.id,
          reason: rule.respond_to?(:reason) ? rule.reason : nil,
          diagnostics: @all_diagnostics.count { |diagnostic| diagnostic.rule == rule.id }
        )
      end.uniq(&:id)
    end

    def components_of(rule)
      roles = %i[source targets consumers components].select { |role| rule.respond_to?(role) }
      return if roles.empty?

      named = roles.flat_map { |role| Array(rule.public_send(role)) }.compact.map(&:to_sym).to_set
      named.empty? && rule.respond_to?(:components) ? nil : named
    end

    # One re-evaluation with the subject's files in no component. Each rule
    # runs on its own, so one that raises is listed as not computed instead of
    # taking the answer for every other rule down with it.
    def blast_radius_for(paths)
      originals = graph.components.values
      graph.restore_components(originals.map { |component| without_paths(component, paths) })
      appearing = []
      vanishing = []
      not_computed = []

      @all_rules.each do |rule|
        unless rule.respond_to?(:id)
          not_computed << { rule: rule.class.name, cause: 'the rule carries no id' }
          next
        end

        before = @all_diagnostics.select { |diagnostic| diagnostic.rule == rule.id }
        after = reported(yield(rule, graph))
        appearing.concat(after.reject { |diagnostic| before_ids(before).include?(diagnostic.fingerprint(root: root)) })
        vanishing.concat(before.reject { |diagnostic| before_ids(after).include?(diagnostic.fingerprint(root: root)) })
      rescue StandardError => e
        not_computed << { rule: rule.id, cause: e.message }
      end

      BlastRadius.new(appearing: appearing, vanishing: vanishing, not_computed: not_computed)
    ensure
      graph.restore_components(originals) if originals
    end

    def without_paths(component, paths)
      copy = Component.new(component.name)
      component.files.each { |file| copy.add_file(file) unless paths.include?(file) }
      component.constant_occurrences.each do |constant, file|
        copy.add_constant(constant, path: file) unless paths.include?(file)
      end
      copy
    end

    def reported(raw)
      raw
        .sort_by { |d| [d.location.path, d.location.line, d.rule, d.message, d.evidence] }
        .uniq { |d| [d.rule, d.message, d.location.path, d.location.line] }
        .reject { |d| graph.suppressions_matching(d).any? || @todo.id_for(d) }
    end

    def before_ids(diagnostics)
      diagnostics.map { |diagnostic| diagnostic.fingerprint(root: root) }.to_set
    end

    def public_face_for(component_name)
      patterns = @all_rules.select do |rule|
        rule.respond_to?(:file_patterns) && rule.respond_to?(:source) && rule.source == component_name
      end.flat_map(&:file_patterns)
      { constants: graph.public_names_for(component_name).to_a.sort, files: patterns.sort }
    end

    def fans_for(component_name)
      fan_in = Hash.new(0)
      fan_out = Hash.new(0)
      graph.dependency_edges.each do |edge|
        sources = graph.source_components_for(edge)
        targets = graph.target_components_for(edge)
        if targets.include?(component_name)
          (sources - [component_name]).each { |source| fan_in[source.to_s] += 1 }
        end
        if sources.include?(component_name)
          (targets - [component_name]).each { |target| fan_out[target.to_s] += 1 }
        end
      end
      [fan_in.sort.to_h, fan_out.sort.to_h]
    end

    def file_document
      {
        defined_constants: defined_constants,
        parse_errors: parse_errors.map { |error| { message: error.message, line: error.location.line } },
        components: reasons_document(components),
        excluded_from: reasons_document(exclusions),
        suppressions: suppressions.map do |suppression|
          { rule: suppression.rule, start_line: suppression.start_line,
            end_line: suppression.end_line.is_a?(Float) ? nil : suppression.end_line, reason: suppression.reason }
        end
      }.merge(shared_document)
    end

    def constant_document
      { constants: constants.map { |entry| constant_entry_document(entry) } }.merge(shared_document)
    end

    def constant_entry_document(entry)
      entry.merge(
        kind: entry[:kind].to_s,
        components: reasons_document(entry[:components]),
        ancestry: entry[:ancestry].map do |link|
          { kind: link.kind.to_s, name: link.name, resolved: link.resolved, resolution: link.resolution.to_s,
            depth: link.depth, origin: link.origin }
        end
      )
    end

    def component_document
      {
        members: members,
        public_face: public_face,
        fan_in: fan_in,
        fan_out: fan_out,
        rules: rules_document,
        diagnostics: diagnostics_document(diagnostics)
      }
    end

    def shared_document
      {
        incoming: incoming.map(&:to_h),
        outgoing: outgoing.map { |edge| edge.to_h.merge(determination: edge.determination&.to_s) },
        census: census,
        rules: rules_document,
        diagnostics: diagnostics_document(diagnostics),
        blast_radius: {
          appearing: diagnostics_document(blast_radius.appearing),
          vanishing: diagnostics_document(blast_radius.vanishing),
          not_computed: blast_radius.not_computed
        }
      }
    end

    def rules_document
      rules.map(&:to_h)
    end

    def diagnostics_document(list)
      list.map { |diagnostic| diagnostic.to_h(root: root) }
    end

    def reasons_document(assignments)
      assignments.sort_by { |component, _| component.to_s }.to_h { |component, reasons| [component.to_s, reasons.to_a] }
    end

    def relative(absolute)
      Pathname(absolute).relative_path_from(Pathname(root)).to_s
    end
  end
end
