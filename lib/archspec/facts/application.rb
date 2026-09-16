# frozen_string_literal: true

module ArchSpec
  module Facts
    Reference = Data.define(:source, :target, :location)
    Method = Data.define(:owner, :definition, :mode, :installation)
    Mixin = Data.define(:owner, :target, :kind, :location)
    Receiver = Data.define(:source, :name, :location, :receiver, :scope)
    Exposure = Data.define(:source, :owner, :scope)
    Gap = Data.define(:source, :message, :location)
    Operations = Data.define(*LIST_KEYS.map(&:to_sym))

    # Applies validated semantic facts, independently of how they were found.
    # Source normalization happens before this boundary; facts establish the
    # resulting relationships, APIs, and execution contexts.
    module Application
      extend self

      MIXIN_TYPES = { include: :includes, prepend: :prepends, extend: :extends,
                      singleton_prepend: :extends }.freeze

      def apply(graph, batches)
        validate(graph, batches)
        batches.each do |batch|
          batch.references.each { |fact| add_dependency(graph, :references_constant, fact.source, fact.target, fact.location) }
          batch.methods.each { |fact| install_method(fact) }
          batch.mixins.each do |fact|
            fact.owner.add_mixin(fact.kind, fact.target)
            add_dependency(graph, MIXIN_TYPES.fetch(fact.kind), fact.owner, fact.target, fact.location, match_location: false)
          end
          batch.exposures.each do |fact|
            graph.expose_instance_methods(fact.source.name, as_owner: exposure_owner_name(fact.owner), scope: fact.scope)
          end
          batch.gaps.each do |fact|
            graph.add_edge(type: :dynamic_feature, from_path: fact.source.path, from_constant: fact.source.name,
              to: fact.message, location: fact.location, confidence: :unknown_due_to_dynamic_feature)
          end
        end
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

      def add_dependency(graph, type, source, target, location, match_location: true)
        return if graph.edges.any? do |edge|
          edge.type == type && edge.from_constant == source.name && edge.from_path == source.path &&
            (!match_location || edge.location == location) && graph.resolve_edge_constant(edge) == target
        end

        graph.add_edge(type: type, from_path: source.path, from_constant: source.name,
          to: target, resolved_to: target, location: location)
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
        seen = Set.new
        edges = graph.edges.flat_map do |edge|
          key = [edge.from_constant, edge.from_path, edge.to, edge.location]
          bindings = if edge.type == :calls_named_method && edge.receiver == :none
                       groups[key]
                     end
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
