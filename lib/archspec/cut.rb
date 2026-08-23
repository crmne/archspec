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
    # component that already reaches what was reached. Nothing else: where the
    # offender's other references land says what it reads, not where it
    # belongs, and a hint that can be wrong is worse than none.
    def for_dependency(graph, _edge, target, reached: nil)
      exposed = exposing_public_name(graph, target, reached) if reached
      return "reference #{exposed} instead, the public face of #{target} that already reaches #{reached}" if exposed

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
  end
end
