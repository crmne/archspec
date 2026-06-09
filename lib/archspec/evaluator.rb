# frozen_string_literal: true

module ArchSpec
  module Evaluator
    extend self

    def evaluate(definition, graph, baseline: Baseline.empty)
      (parser_diagnostics(graph) + definition.rules.flat_map { |rule| rule.evaluate(graph) })
        .reject { |diagnostic| graph.suppressed?(diagnostic) }
        .reject { |diagnostic| baseline.include?(diagnostic) }
        .sort_by do |diagnostic|
        [diagnostic.location.path, diagnostic.location.line, diagnostic.rule,
         diagnostic.message]
      end
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
