# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#must_be_empty. Flags every file in a
    # component that is meant to hold none.
    class MustBeEmptyRule
      attr_reader :source

      def initialize(source)
        @source = source.to_sym
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
            message: "#{source} must stay empty",
            location: SourceLocation.point(path, 1, 1),
            evidence: "#{relative} belongs to #{source}"
          )
        end
      end
    end
  end
end
