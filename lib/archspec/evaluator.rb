# frozen_string_literal: true

module ArchSpec
  module Evaluator
    extend self

    def evaluate(definition, graph, todo: Todo.empty)
      diagnostics = parser_diagnostics(graph) + definition.rules.flat_map { |rule| rule.evaluate(graph) }

      # Deduplicate before rejecting. One statement can raise several diagnostics
      # that differ only in evidence, because `include Foo` is both an includes
      # edge and a constant reference. Todo entries are matched on evidence, so
      # rejecting first would drop the recorded diagnostic and report its
      # surviving sibling as new.
      diagnostics
        .sort_by { |d| [d.location.path, d.location.line, d.rule, d.message, d.evidence] }
        .uniq { |d| [d.rule, d.message, d.location.path, d.location.line] }
        .reject { |diagnostic| graph.suppressed?(diagnostic) || todo.include?(diagnostic) }
    end

    private

    def parser_diagnostics(graph)
      graph.files.values.flat_map do |file|
        file.parse_errors.map do |parse_error|
          Diagnostic.new(
            rule: 'parser.syntax',
            message: parse_error.message,
            location: parse_error.location,
            evidence: file.relative_path,
            confidence: :high
          )
        end
      end
    end
  end
end
