# frozen_string_literal: true

module ArchSpec
  # The smallest change that would satisfy a verdict, read off the graph at
  # the moment the breach is found. Every suggestion names a constant, a file,
  # a component or an edge the graph holds; when nothing in the graph points at
  # a fix, the suggestion says so rather than guess.
  module Cut
    NONE = 'no cut the graph can see'

    extend self

    # For a reference into a component: the public declaration of that
    # component that already reaches what was reached, else the component the
    # offender's other dependencies mostly land in.
    def for_dependency(graph, edge, target, reached: nil)
      exposed = exposing_public_name(graph, target, reached) if reached
      if exposed
        return "reference #{exposed} instead, the public face of #{target} that already reaches #{reached}"
      end

      home = likely_home(graph, edge, excluding: [target])
      return "move #{graph.edge_source_name(edge)} to #{home}, where its other dependencies already land" if home

      NONE
    end

    # For a cycle: the edge with the fewest dependencies behind it, counted
    # over the pairs the rule walked.
    def for_cycle(cycle, counts)
      pairs = cycle.each_cons(2).to_a
      return NONE if pairs.empty?

      source, target = pairs.min_by { |pair| [counts.fetch(pair, 0), pair.map(&:to_s)] }
      weight = counts.fetch([source, target], 0)
      "break #{source} -> #{target}, the edge of this cycle with the fewest dependencies behind it (#{weight})"
    end

    # For a concern that names its includer: the reference to move out of the
    # concern, into the includer that owns what it reaches.
    def for_concern(concern, includer, reached)
      "move what reaches #{reached} out of #{concern}; #{includer} owns it"
    end

    private

    def exposing_public_name(graph, target, reached)
      graph.public_names_for(target).sort.find do |name|
        next false if name == reached
        next false if graph.constants_named(name).empty?

        graph.dependency_edges.any? do |edge|
          edge.from_constant == name && graph.resolve_edge_constant(edge) == reached
        end
      end
    end

    def likely_home(graph, edge, excluding:)
      own = graph.source_components_for(edge)
      tally = Hash.new(0)

      graph.dependency_edges.each do |other|
        next if other.equal?(edge)
        next unless same_source?(edge, other)

        graph.target_components_for(other).each do |component|
          next if own.include?(component) || excluding.include?(component)

          tally[component] += 1
        end
      end

      return if tally.empty?

      best = tally.values.max
      homes = tally.select { |_, count| count == best }.keys
      homes.first if homes.size == 1
    end

    def same_source?(edge, other)
      if edge.from_constant
        other.from_constant == edge.from_constant
      else
        other.from_constant.nil? && other.from_path == edge.from_path
      end
    end
  end
end
