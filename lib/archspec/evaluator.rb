# frozen_string_literal: true

module ArchSpec
  module Evaluator
    extend self

    def evaluate(definition, graph, todo: Todo.empty)
      diagnostics = parser_diagnostics(graph) + definition.rules.flat_map { |rule| rule.evaluate(graph) }

      diagnostics
        .reject { |diagnostic| graph.suppressed?(diagnostic) || todo.include?(diagnostic) }
        .sort_by { |d| [d.location.path, d.location.line, d.rule, d.message, d.evidence] }
        .uniq { |d| [d.rule, d.message, d.location.path, d.location.line] }
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
