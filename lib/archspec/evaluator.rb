module ArchSpec
  class Evaluator
    def initialize(definition, baseline: Baseline.empty)
      @definition = definition
      @baseline = baseline
    end

    def call(graph)
      definition.rules.flat_map { |rule| rule.call(graph) }
        .reject { |diagnostic| baseline.include?(diagnostic) }
        .sort_by { |diagnostic| [diagnostic.location.path, diagnostic.location.line, diagnostic.rule, diagnostic.message] }
    end

    private

    attr_reader :definition, :baseline
  end
end
