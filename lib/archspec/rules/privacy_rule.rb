# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#public_api. Flags references from
    # outside the component to constants that are not part of its public API.
    class PublicApiRule
      attr_reader :source, :file_patterns, :constants, :namespaces

      def initialize(source, files: [], constants: nil, namespaces: nil)
        @source = source.to_sym
        @file_patterns = Array(files).flatten.compact.map(&:to_s)
        @constants = Array(constants).compact.map { |value| normalize_constant(value) }
        @namespaces = Array(namespaces).compact.map { |value| normalize_constant(value) }
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

        public_names = public_constant_names(graph)

        graph.dependency_edges.filter_map do |edge|
          next if component.files.include?(edge.from_path)

          resolved = graph.resolve_constant_reference(edge.to, edge.from_constant)
          next unless graph.component_names_for_constant(resolved).include?(source)
          next if public?(resolved, public_names)

          Diagnostic.new(
            rule: id,
            message: "#{resolved} is private to #{source}",
            location: edge.location,
            evidence: "#{edge.from_constant || edge.from_path} #{edge.type} #{resolved}"
          )
        end
      end

      private

      def public_constant_names(graph)
        paths = file_patterns.flat_map do |pattern|
          Dir.glob(File.absolute_path(pattern, graph.root))
        end.map { |path| File.expand_path(path) }.to_set

        names = graph.constants.select { |constant| paths.include?(constant.path) }.map(&:name)
        (names + constants).to_set
      end

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
