# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::Context#no_cycles. Flags dependency cycles between
    # components, reporting each cycle once in a canonical order.
    class NoCyclesRule
      attr_reader :components

      def initialize(among: nil)
        @components = Array(among).compact.map(&:to_sym)
      end

      def id
        'dependencies.no_cycles'
      end

      def evaluate(graph)
        cycles(graph).map do |cycle|
          location = first_location_for_cycle(graph, cycle) || SourceLocation.new(graph.root, 1, 1)
          Diagnostic.new(
            rule: id,
            message: "component dependency cycle: #{cycle.join(' -> ')}",
            location: location,
            evidence: cycle.join(' -> ')
          )
        end
      end

      private

      def cycles(graph)
        adjacency = {}
        graph.component_dependency_pairs(only: components).each do |source, target|
          next if source == target

          (adjacency[source] ||= Set.new).add(target)
        end

        found = Set.new
        result = []

        adjacency.each_key do |start|
          walk(adjacency, start, start, [], found, result)
        end

        result
      end

      def walk(adjacency, start, node, path, found, result)
        next_path = path + [node]

        adjacency.fetch(node, []).each do |target|
          if target == start
            cycle = canonical_cycle(next_path + [start])
            key = cycle.join("\0")
            next if found.include?(key)

            found.add(key)
            result << cycle
          elsif !path.include?(target)
            walk(adjacency, start, target, next_path, found, result)
          end
        end
      end

      def canonical_cycle(cycle)
        body = cycle[0...-1]
        rotations = body.each_index.map { |index| body.rotate(index) }
        canonical = rotations.min_by { |rotation| rotation.map(&:to_s) }
        canonical + [canonical.first]
      end

      def first_location_for_cycle(graph, cycle)
        source, target = cycle
        graph.dependency_edges.find do |edge|
          graph.component_names_for_path(edge.from_path).include?(source) &&
            graph.target_components_for(edge).include?(target)
        end&.location
      end
    end
  end
end
