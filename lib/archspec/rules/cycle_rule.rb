# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::Context#no_cycles. Flags each group of components
    # that depend on each other, reporting the group once with an example cycle.
    class NoCyclesRule
      attr_reader :components

      def initialize(among: nil)
        @components = Array(among).compact.map(&:to_sym)
      end

      def id
        'dependencies.no_cycles'
      end

      # One diagnostic per strongly connected component. Every component in an
      # SCC reaches every other one, so the group is the thing to break up;
      # enumerating its elementary cycles instead reports the same tangle
      # exponentially many times.
      def evaluate(graph)
        locations = dependency_locations(graph)
        adjacency = adjacency_for(locations)

        StronglyConnectedComponents.of(adjacency).filter_map do |group|
          next if group.size < 2

          cycle = shortest_cycle(adjacency, group)
          next unless cycle

          Diagnostic.new(
            rule: id,
            message: message_for(group, cycle),
            location: locations[[cycle[0], cycle[1]]] || SourceLocation.point(graph.root, 1, 1),
            evidence: cycle.join(' -> ')
          )
        end
      end

      private

      # Every component pair with a dependency between them, mapped to the first
      # edge that creates it so a reported cycle can point at real source.
      def dependency_locations(graph)
        allowed = components.to_set
        locations = {}

        graph.dependency_edges.each do |edge|
          sources = graph.source_components_for(edge)
          sources &= allowed unless allowed.empty?
          next if sources.empty?

          targets = graph.target_components_for(edge)
          sources.each do |source|
            targets.each do |target|
              locations[[source, target]] ||= edge.location unless source == target
            end
          end
        end

        locations
      end

      def adjacency_for(locations)
        locations.each_key.with_object({}) do |(source, target), adjacency|
          (adjacency[source] ||= []) << target
        end
      end

      # The tightest loop in the group, as the first thing to break. Every
      # member is a valid starting point, so canonicalize before comparing to
      # keep the choice stable across runs.
      def shortest_cycle(adjacency, group)
        members = group.to_set

        group.sort
             .filter_map { |node| shortest_cycle_through(adjacency, node, members) }
             .map { |cycle| canonical_cycle(cycle) }
             .min_by { |cycle| [cycle.size, cycle.map(&:to_s)] }
      end

      def shortest_cycle_through(adjacency, start, members)
        previous = {}
        queue = [start]

        until queue.empty?
          node = queue.shift
          adjacency.fetch(node, []).each do |target|
            next unless members.include?(target)
            return path_to(previous, start, node) if target == start
            next if previous.key?(target)

            previous[target] = node
            queue << target
          end
        end

        nil
      end

      def path_to(previous, start, node)
        path = [node]
        path.unshift(previous[path.first]) while previous.key?(path.first)
        path + [start]
      end

      def message_for(group, cycle)
        return "component dependency cycle: #{cycle.join(' -> ')}" if cycle.size - 1 == group.size

        "component dependency cycle among #{group.size} components: #{group.sort.join(', ')}"
      end

      def canonical_cycle(cycle)
        body = cycle[0...-1]
        rotations = body.each_index.map { |index| body.rotate(index) }
        canonical = rotations.min_by { |rotation| rotation.map(&:to_s) }
        canonical + [canonical.first]
      end
    end

    # Tarjan's algorithm: the components that mutually reach each other, in one
    # pass over the graph.
    class StronglyConnectedComponents
      def self.of(adjacency)
        new(adjacency).components
      end

      def initialize(adjacency)
        @adjacency = adjacency
        @index = 0
        @indexes = {}
        @lowlinks = {}
        @stack = []
        @on_stack = Set.new
        @found = []
      end

      def components
        @adjacency.each_key { |node| visit(node) unless @indexes.key?(node) }
        @found
      end

      private

      def visit(node)
        @indexes[node] = @lowlinks[node] = @index
        @index += 1
        @stack.push(node)
        @on_stack.add(node)

        @adjacency.fetch(node, []).each { |target| follow(node, target) }

        @found << pop_component(node) if @lowlinks[node] == @indexes[node]
      end

      def follow(node, target)
        if @indexes.key?(target)
          @lowlinks[node] = [@lowlinks[node], @indexes[target]].min if @on_stack.include?(target)
        else
          visit(target)
          @lowlinks[node] = [@lowlinks[node], @lowlinks[target]].min
        end
      end

      def pop_component(root)
        component = []

        loop do
          node = @stack.pop
          @on_stack.delete(node)
          component << node
          break if node == root
        end

        component
      end
    end
  end
end
