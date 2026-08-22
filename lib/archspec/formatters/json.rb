# frozen_string_literal: true

require 'json'

module ArchSpec
  module Formatters
    module JSON
      module_function

      def print(output = $stdout, graph:, diagnostics:)
        output.puts ::JSON.pretty_generate(
          files: graph.files.size,
          constants: graph.constants.size,
          facts: graph.edges.size,
          facts_files: graph.facts_files.map do |file|
            {
              path: file.relative_path,
              producer: file.producer,
              producer_version: file.producer_version,
              commit: file.commit,
              dirty: file.dirty,
              entries: file.entries,
              misses: file.misses
            }
          end,
          violations: diagnostics.map { |diagnostic| diagnostic.to_h(root: graph.root) }
        )
      end
    end
  end
end
