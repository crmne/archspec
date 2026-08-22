# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#must_be_empty. Flags every file in a
    # component that is meant to hold none.
    class MustBeEmptyRule
      include Annotated

      attr_reader :source, :because

      def initialize(source, because: nil, since: nil)
        @source = source.to_sym
        @because = because
        annotate(because: because, since: since)
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

          diagnostic(
            rule: id,
            message: because ? "#{source} must stay empty: #{because}" : "#{source} must stay empty",
            location: SourceLocation.point(path, 1, 1),
            evidence: "#{relative} belongs to #{source}"
          )
        end
      end
    end
  end
end
