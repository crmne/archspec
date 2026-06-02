require "json"

module ArchSpec
  module Formatters
    module JSON
      extend self

      def print(output = $stdout, graph:, diagnostics:)
        output.puts ::JSON.pretty_generate(
          files: graph.files.size,
          constants: graph.constants.size,
          facts: graph.edges.size,
          violations: diagnostics.map { |diagnostic| diagnostic.to_h(root: graph.root) }
        )
      end
    end
  end
end
