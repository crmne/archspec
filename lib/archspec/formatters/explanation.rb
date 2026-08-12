# frozen_string_literal: true

module ArchSpec
  module Formatters
    # Renders <tt>archspec explain</tt>: why a file or constant belongs to its
    # components, and the facts ArchSpec found for it. Raises ArchSpec::Error
    # when the subject matches no file and no constant.
    module Explanation
      module_function

      def print(output = $stdout, graph:, subject:)
        path = File.expand_path(subject, graph.root)

        if graph.files.key?(path)
          explain_file(output, graph, path)
        else
          explain_constant(output, graph, subject)
        end
      end

      def explain_file(output, graph, path)
        file = graph.files.fetch(path)
        output.puts file.relative_path
        output.puts "  defined constants: #{graph.constants_for_path(path).map(&:name).join(', ')}"
        print_parse_errors(output, file)
        print_component_reasons(output, graph.component_assignment_reasons_for_path(path))
        print_suppressions(output, file)

        facts = graph.edges.select { |edge| edge.from_path == path }
        if facts.empty?
          output.puts '  outgoing facts: (none)'
        else
          output.puts '  outgoing facts:'
          facts.each do |edge|
            output.puts "    #{edge.type} #{edge.to} at #{edge.location.line}:#{edge.location.column}"
          end
        end
      end

      def explain_constant(output, graph, subject)
        constants = graph.constants_named(subject)
        raise Error, "No file or constant found for #{subject.inspect}" if constants.empty?

        constants.each do |constant|
          output.puts constant.name
          output.puts "  kind: #{constant.kind}"
          output.puts "  file: #{constant.location.relative_path(graph.root)}:#{constant.location.line}"
          print_component_reasons(
            output,
            graph.component_assignment_reasons_for_constant(constant.name, path: constant.path)
          )
          output.puts "  superclass: #{constant.superclass || '(none)'}"
          output.puts "  instance methods: #{constant.instance_methods.to_a.sort.join(', ')}"
          output.puts "  class methods: #{constant.class_methods.to_a.sort.join(', ')}"
        end
      end

      def print_component_reasons(output, assignments)
        if assignments.empty?
          output.puts '  components: (none)'
          return
        end

        output.puts '  components:'
        assignments.sort_by { |name, _reasons| name.to_s }.each do |name, reasons|
          output.puts "    #{name}: #{reasons.empty? ? '(no recorded reason)' : reasons.join('; ')}"
        end
      end

      def print_suppressions(output, file)
        return if file.suppressions.empty?

        output.puts '  suppressions:'
        file.suppressions.each do |suppression|
          rule = suppression.rule || '*'
          reason = suppression.reason ? " -- #{suppression.reason}" : ''
          output.puts "    #{rule} on line #{line_range(suppression)}#{reason}"
        end
      end

      def print_parse_errors(output, file)
        return if file.parse_errors.empty?

        output.puts '  parse errors:'
        file.parse_errors.each do |parse_error|
          output.puts "    #{parse_error.location.line}:#{parse_error.location.column} #{parse_error.message}"
        end
      end

      def line_range(suppression)
        if suppression.end_line == Float::INFINITY
          "#{suppression.start_line}-EOF"
        elsif suppression.start_line == suppression.end_line
          suppression.start_line
        else
          "#{suppression.start_line}-#{suppression.end_line}"
        end
      end
    end
  end
end
