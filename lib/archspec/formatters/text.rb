module ArchSpec
  module Formatters
    class Text
      def initialize(output = $stdout)
        @output = output
      end

      def print(graph:, diagnostics:)
        if diagnostics.empty?
          output.puts "ArchSpec passed: #{graph.files.size} files, #{graph.constants.size} constants, #{graph.edges.size} facts checked."
          return
        end

        output.puts "#{diagnostics.size} architecture #{diagnostics.size == 1 ? "violation" : "violations"}"
        output.puts

        diagnostics.each do |diagnostic|
          output.puts "[#{diagnostic.rule}] #{diagnostic.location.relative_path(graph.root)}:#{diagnostic.location.line}:#{diagnostic.location.column}"
          output.puts "  #{diagnostic.message}"
          output.puts "  evidence: #{diagnostic.evidence}"
          output.puts "  confidence: #{diagnostic.confidence}"
          output.puts "  id: #{diagnostic.fingerprint(root: graph.root)}"
          output.puts
        end
      end

      private

      attr_reader :output
    end
  end
end
