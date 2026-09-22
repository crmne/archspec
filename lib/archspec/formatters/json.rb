# frozen_string_literal: true

require 'json'

module ArchSpec
  module Formatters
    module JSON
      module_function

      def print(output = $stdout, graph:, diagnostics:, obsolete_todo: nil)
        report = {
          files: graph.files.size,
          constants: graph.constants.size,
          facts: graph.edges.size,
          analysis: graph.analysis_census,
          violations: diagnostics.map { |diagnostic| diagnostic.to_h(root: graph.root) }
        }
        report[:obsolete_todo] = obsolete_todo if obsolete_todo

        output.puts ::JSON.pretty_generate(report)
      end
    end
  end
end
