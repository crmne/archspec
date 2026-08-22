# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#cannot_reference_includers. A concern
    # is a module mixed into other classes; this flags a concern that names the
    # very constant that includes it, which is a circular knowledge dependency.
    class ConcernIndependenceRule
      include Annotated

      MIXIN_TYPES = %i[includes prepends extends].freeze

      attr_reader :source

      def initialize(source, because: nil, since: nil)
        @source = source.to_sym
        annotate(because: because, since: since)
      end

      def merge_key
        [self.class, source]
      end

      def id
        'concerns.independence'
      end

      def evaluate(graph)
        component = graph.components[source]
        return [] unless component

        includers = includers_by_module(graph)

        graph.dependency_edges.filter_map do |edge|
          next unless edge.from_constant && component.constants.include?(edge.from_constant)

          consumers = includers[edge.from_constant]
          next if consumers.empty?

          target = graph.resolve_edge_constant(edge)
          includer = consumers.find { |name| target == name || target.start_with?("#{name}::") }
          next unless includer

          diagnostic(
            rule: id,
            message: "#{edge.from_constant} must not reference its includer #{includer}",
            location: edge.location,
            evidence: "#{edge.from_constant} #{edge.verb} #{target}",
            suggested_action: Cut.for_concern(edge.from_constant, includer, target)
          )
        end
      end

      private

      # Maps each mixed-in module to the set of constants that mix it in.
      def includers_by_module(graph)
        map = Hash.new { |hash, key| hash[key] = Set.new }

        graph.edges.each do |edge|
          next unless MIXIN_TYPES.include?(edge.type) && edge.from_constant

          mod = graph.resolve_edge_constant(edge)
          map[mod].add(edge.from_constant) unless mod == edge.from_constant
        end

        map
      end
    end
  end
end
