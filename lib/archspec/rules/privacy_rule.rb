# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#public_api. Flags references from
    # outside the component to constants that are not part of its public API.
    class PublicApiRule
      include Annotated

      attr_reader :source, :file_patterns, :constants, :namespaces

      def initialize(source, files: [], constants: nil, namespaces: nil, because: nil, since: nil)
        @source = source.to_sym
        @file_patterns = Array(files).flatten.compact.map(&:to_s)
        @constants = Array(constants).compact.map { |value| normalize_constant(value) }
        @namespaces = Array(namespaces).compact.map { |value| normalize_constant(value) }
        annotate(because: because, since: since)
      end

      def merge_key
        [self.class, source]
      end

      def merge!(other)
        @file_patterns |= other.file_patterns
        @constants |= other.constants
        @namespaces |= other.namespaces
        self
      end

      def id
        'dependencies.privacy'
      end

      def evaluate(graph)
        component = graph.components[source]
        return [] unless component

        public_names = public_names(graph)

        graph.dependency_edges.filter_map do |edge|
          next if graph.source_components_for(edge).include?(source)

          resolved = graph.resolve_edge_constant(edge)
          next unless graph.component_names_for_constant(resolved).include?(source)
          next if public?(resolved, public_names)

          diagnostic(
            rule: id,
            message: "#{resolved} is private to #{source}",
            location: edge.location,
            evidence: graph.edge_evidence(edge, resolved),
            confidence: edge.confidence,
            suggested_action: Cut.for_dependency(graph, edge, source, reached: resolved)
          )
        end
      end

      # The constants declared public by file or by name, which the evaluator
      # records on the graph so a cut elsewhere can point at them.
      def public_names(graph)
        paths = file_patterns.flat_map do |pattern|
          Dir.glob(File.absolute_path(pattern, graph.root))
        end.map { |path| File.expand_path(path) }.to_set

        names = graph.constants.select { |constant| paths.include?(constant.path) }.map(&:name)
        (names + constants).to_set
      end

      private

      # Names from public files and constants: match exactly. Reopened
      # namespace modules land in public files too, so prefix matching there
      # would make the whole namespace public. Use namespace: for prefixes.
      def public?(name, public_names)
        return true if public_names.include?(name)

        namespaces.any? do |namespace|
          name == namespace || name.start_with?("#{namespace}::")
        end
      end

      def normalize_constant(value)
        value.to_s.sub(/\A::/, '')
      end
    end
  end
end
