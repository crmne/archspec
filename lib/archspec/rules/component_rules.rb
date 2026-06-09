# frozen_string_literal: true

module ArchSpec
  module Rules
    class MustBeEmptyRule
      attr_reader :source, :because

      def initialize(source, because: nil)
        @source = source.to_sym
        @because = because
      end

      def merge_key
        [self.class, source]
      end

      def id
        'components.empty'
      end

      def evaluate(graph)
        component = graph.components[source]
        return [] unless component

        component.files.sort.map do |path|
          relative = graph.files[path]&.relative_path || path

          Diagnostic.new(
            rule: id,
            message: because ? "#{source} must stay empty: #{because}" : "#{source} must stay empty",
            location: SourceLocation.new(path, 1, 1),
            evidence: "#{relative} belongs to #{source}"
          )
        end
      end
    end
  end
end
