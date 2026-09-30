# frozen_string_literal: true

module ArchSpec
  module Facts
    Reference = Data.define(:source, :target, :location)
    Method = Data.define(:owner, :definition, :mode, :installation)
    Mixin = Data.define(:owner, :target, :kind, :location)
    Receiver = Data.define(:source, :name, :location, :receiver, :scope)
    Exposure = Data.define(:source, :owner, :scope)
    Gap = Data.define(:source, :message, :location)
    Resolve = Data.define(:source, :message, :location)
    # One document's facts. The producer is recorded on imported edges; facts
    # applied in memory by a static pass have none.
    Operations = Data.define(*LIST_KEYS.map(&:to_sym), :producer)

    # Applies validated semantic facts, independently of how they were found.
    # Source normalization happens before this boundary; facts establish the
    # resulting relationships, APIs, and execution contexts.
    module Application
      extend self

      MIXIN_TYPES = { include: :includes, prepend: :prepends, extend: :extends,
                      singleton_prepend: :extends }.freeze

      def apply(graph, batches)
        validate(graph, batches)
        dependencies = dependency_index(graph, batches)
        batches.each do |batch|
          producer = batch.producer
          batch.references.each do |fact|
            add_dependency(graph, dependencies, :references_constant, fact.source, fact.target, fact.location, producer)
          end
          batch.methods.each { |fact| install_method(fact) }
          batch.mixins.each do |fact|
            fact.owner.add_mixin(fact.kind, "::#{fact.target}")
            add_dependency(graph, dependencies, MIXIN_TYPES.fetch(fact.kind), fact.owner, fact.target, fact.location,
              producer, match_location: false)
          end
          batch.exposures.each do |fact|
            graph.expose_instance_methods(fact.source.name, as_owner: exposure_owner_name(fact.owner), scope: fact.scope)
          end
          batch.gaps.each do |fact|
            graph.add_edge(type: :dynamic_feature, from_path: fact.source.path, from_constant: fact.source.name,
              to: fact.message, location: fact.location, confidence: :unknown_due_to_dynamic_feature,
              producer: producer)
          end
        end
        resolve_gaps(graph, batches.flat_map(&:resolves))
        graph.clear_method_caches
        bind_receivers(graph, batches.flat_map(&:receivers))
        graph
      end

      def validate(graph, batches)
        validate_exposures(graph, batches.flat_map(&:exposures))
      end

      private

      def validate_exposures(graph, facts)
        facts.group_by { |fact| fact.source.name }.each do |source, entries|
          projections = entries.map { |fact| [exposure_owner_name(fact.owner), fact.scope] }
          existing = graph.method_exposure(source)
          projections << existing if existing
          raise Error, "conflicting method exposure facts for #{source}" if projections.uniq.size > 1
        end
      end

      def exposure_owner_name(owner)
        owner.respond_to?(:name) ? owner.name : owner
      end

      # Existing dependency edges, keyed with and without their location, so
      # each fact checks for a duplicate without scanning the whole graph.
      def dependency_index(graph, batches)
        sources = batches.flat_map { |batch| batch.references.map(&:source) + batch.mixins.map(&:owner) }
                         .to_set(&:name)
        return Set.new if sources.empty?

        types = MIXIN_TYPES.values.to_set << :references_constant
        graph.edges.each_with_object(Set.new) do |edge, index|
          next unless sources.include?(edge.from_constant) && types.include?(edge.type)

          key = [edge.type, edge.from_constant, edge.from_path, graph.resolve_edge_constant(edge)]
          index << key << (key + [edge.location])
        end
      end

      def add_dependency(graph, index, type, source, target, location, producer, match_location: true)
        key = [type, source.name, source.path, target]
        return unless index.add?(match_location ? key + [location] : key)

        index << key << (key + [location])
        graph.add_edge(type: type, from_path: source.path, from_constant: source.name,
          to: target, resolved_to: target, location: location, producer: producer)
      end

      # A producer that observed what a static gap left open settles it, so
      # the gap no longer counts against the analysis.
      def resolve_gaps(graph, facts)
        return if facts.empty?

        resolved = facts.group_by { |fact| [fact.source.name, fact.source.path, fact.location] }
        graph.edges.reject! do |edge|
          edge.type == :dynamic_feature &&
            resolved.fetch([edge.from_constant, edge.from_path, edge.location], []).any? do |fact|
              fact.message.nil? || edge.to == fact.message
            end
        end
      end

      def install_method(fact)
        owner = fact.owner
        definition = fact.definition
        existing = owner.method_definitions.select do |method|
          method.name == definition.name && method.scope == definition.scope
        end
        return if fact.mode == :if_missing && existing.any?

        if fact.mode == :define
          return if existing.any? do |method|
            method.location.path == owner.path && fact.installation.path == owner.path &&
              ([method.location.line, method.location.column] <=>
               [fact.installation.line, fact.installation.column]).positive?
          end

          owner.method_definitions.reject! { |method| existing.include?(method) }
        end
        return if owner.method_definitions.include?(definition)

        owner.method_definitions << definition
        (definition.scope == :class ? owner.class_methods : owner.instance_methods).add(definition.name)
      end

      def bind_receivers(graph, facts)
        return if facts.empty?

        groups = facts.group_by { |fact| [fact.source.name, fact.source.path, fact.name, fact.location] }
        sources = facts.to_set { |fact| fact.source.name }
        seen = Set.new
        edges = graph.edges.flat_map do |edge|
          next edge unless sources.include?(edge.from_constant) && edge.type == :calls_named_method && edge.receiver == :none

          key = [edge.from_constant, edge.from_path, edge.to, edge.location]
          bindings = groups[key]
          next edge unless bindings

          bindings.filter_map do |fact|
            next unless seen.add?([key, fact.receiver, fact.scope])

            edge.with(resolved_receiver: fact.receiver, receiver_scope: fact.scope,
              resolved_method: graph.resolve_method_alias(fact.receiver, edge.to, fact.scope))
          end
        end
        graph.edges.replace(edges)
      end
    end
  end
end
