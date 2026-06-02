require "json"

module ArchSpec
  module Formatters
    class JSON
      def initialize(output = $stdout)
        @output = output
      end

      def print(graph:, diagnostics:)
        output.puts ::JSON.pretty_generate(
          files: graph.files.size,
          constants: graph.constants.size,
          facts: graph.edges.size,
          violations: diagnostics.map { |diagnostic| diagnostic.to_h(root: graph.root) }
        )
      end

      private

      attr_reader :output
    end
  end
end
