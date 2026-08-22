# frozen_string_literal: true

require 'json'

module ArchSpec
  module Formatters
    module JSON
      module_function

      def print(output = $stdout, graph:, diagnostics:)
        output.puts ::JSON.pretty_generate(document(graph, diagnostics))
      end

      # The plain document plus the delta: +violations+ keeps its meaning as
      # the full current list, and the buckets sit beside it.
      def print_delta(output = $stdout, graph:, diagnostics:, delta:, mode:)
        output.puts ::JSON.pretty_generate(
          document(graph, diagnostics).merge(
            mode: mode,
            baseline: {
              commit: delta.receipt.commit,
              dirty: delta.receipt.dirty,
              archspec_version: delta.receipt.archspec_version,
              rule_ids: delta.receipt.rule_ids
            },
            introduced: delta.introduced.map { |diagnostic| diagnostic.to_h(root: graph.root) },
            resolved: delta.resolved.map { |diagnostic| diagnostic.to_h(root: graph.root) },
            declared: delta.declared.map { |diagnostic| diagnostic.to_h(root: graph.root) },
            carried: delta.carried.size,
            edges: { added: delta.edges_added, removed: delta.edges_removed },
            changed_files_read: delta.changed_files_read
          )
        )
      end

      def document(graph, diagnostics)
        {
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
              entries_by_type: file.counts,
              skipped: graph.facts_merges[file.relative_path].sort.to_h,
              misses: file.misses
            }
          end,
          census: graph.census.report,
          dating_note: graph.dating_note,
          violations: diagnostics.map { |diagnostic| diagnostic.to_h(root: graph.root) }
        }
      end
    end
  end
end
