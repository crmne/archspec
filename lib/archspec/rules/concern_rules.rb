# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#cannot_reference_includers. A concern
    # is a module mixed into other classes; this flags a concern that names the
    # very constant that includes it, which is a circular knowledge dependency.
    class ConcernIndependenceRule
      MIXIN_TYPES = %i[includes prepends extends].freeze

      attr_reader :source

      def initialize(source)
        @source = source.to_sym
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
          owner = definer(graph, target)
          next unless consumers.include?(owner)

          Diagnostic.new(
            rule: id,
            message: "#{edge.from_constant} must not reference its includer #{owner}",
            location: edge.location,
            evidence: "#{edge.from_constant} #{edge.verb} #{target}"
          )
        end
      end

      private

      # The class or module a reference reaches: the constant itself when it
      # names one, or the namespace whose body defines a value constant.
      # Chat::Interruptions::GRACE belongs to the concern Chat::Interruptions,
      # and Chat::Closure is a class of its own, so neither names the includer
      # Chat; Chat::LIMIT does.
      def definer(graph, constant)
        return constant if graph.constants_named(constant).any? { |node| node.class? || node.module? }

        namespace, separator, = constant.rpartition('::')
        separator.empty? ? constant : namespace
      end

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
