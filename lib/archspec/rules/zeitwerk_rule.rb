module ArchSpec
  module Rules
    class ZeitwerkNamingRule
      def id
        "zeitwerk.naming"
      end

      def evaluate(graph)
        graph.files.values.filter_map do |file|
          next unless file.expected_constant

          defined = graph.constants_for_path(file.path).map(&:name)
          next if defined.include?(file.expected_constant)

          Diagnostic.new(
            rule: id,
            message: "#{file.relative_path} should define #{file.expected_constant}",
            location: SourceLocation.new(file.path, 1, 1),
            evidence: "defined constants: #{defined.empty? ? "(none)" : defined.join(", ")}"
          )
        end
      end
    end
  end
end
