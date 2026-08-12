# frozen_string_literal: true

module ArchSpec
  module Formatters
    # Renders <tt>archspec explain</tt>: why a file or constant belongs to its
    # components, and the facts ArchSpec found for it, in the same visual
    # language as the check output. Raises ArchSpec::Error when the subject
    # matches no file and no constant.
    module Explanation
      module_function

      def print(output = $stdout, graph:, subject:)
        style = Style.new(output)
        path = File.expand_path(subject, graph.root)

        if graph.files.key?(path)
          explain_file(output, style, graph, path)
        else
          explain_constant(output, style, graph, subject)
        end
      end

      def explain_file(output, style, graph, path)
        file = graph.files.fetch(path)
        output.puts style.bold(file.relative_path)
        output.puts
        output.puts "  #{style.note('defined constants:')} #{graph.constants_for_path(path).map(&:name).join(', ')}"
        print_parse_errors(output, style, file)
        print_component_reasons(output, style, graph.component_assignment_reasons_for_path(path))
        print_suppressions(output, style, file)
        print_facts(output, style, graph.edges.select { |edge| edge.from_path == path })
      end

      def explain_constant(output, style, graph, subject)
        constants = graph.constants_named(subject)
        raise Error, "no file or constant found for #{subject.inspect}" if constants.empty?

        constants.each_with_index do |constant, index|
          output.puts unless index.zero?
          output.puts style.bold(constant.name)
          output.puts
          output.puts "  #{style.note('kind:')} #{constant.kind}"
          output.puts "  #{style.note('file:')} #{constant.location.relative_path(graph.root)}:#{constant.location.line}"
          print_component_reasons(
            output, style,
            graph.component_assignment_reasons_for_constant(constant.name, path: constant.path)
          )
          output.puts "  #{style.note('superclass:')} #{constant.superclass || '(none)'}"
          output.puts "  #{style.note('instance methods:')} #{constant.instance_methods.to_a.sort.join(', ')}"
          output.puts "  #{style.note('class methods:')} #{constant.class_methods.to_a.sort.join(', ')}"
        end
      end

      def print_component_reasons(output, style, assignments)
        if assignments.empty?
          output.puts "  #{style.note('components:')} (none)"
          return
        end

        output.puts "  #{style.note('components:')}"
        assignments.sort_by { |name, _reasons| name.to_s }.each do |name, reasons|
          output.puts "    #{name}: #{reasons.empty? ? '(no recorded reason)' : reasons.join('; ')}"
        end
      end

      def print_suppressions(output, style, file)
        return if file.suppressions.empty?

        output.puts "  #{style.note('suppressions:')}"
        in_gutters(file.suppressions.map { |suppression| line_range(suppression) }) do |gutter, index|
          suppression = file.suppressions[index]
          rule = suppression.rule || '*'
          reason = suppression.reason ? " -- #{suppression.reason}" : ''
          output.puts "    #{style.faint(gutter)} #{rule}#{reason}"
        end
      end

      def print_parse_errors(output, style, file)
        return if file.parse_errors.empty?

        output.puts "  #{style.note('parse errors:')}"
        locations = file.parse_errors.map { |error| "#{error.location.line}:#{error.location.column}" }
        in_gutters(locations) do |gutter, index|
          output.puts "    #{style.faint(gutter)} #{file.parse_errors[index].message}"
        end
      end

      def print_facts(output, style, facts)
        if facts.empty?
          output.puts "  #{style.note('outgoing facts:')} (none)"
          return
        end

        output.puts "  #{style.note('outgoing facts:')}"
        locations = facts.map { |edge| "#{edge.location.line}:#{edge.location.column}" }
        in_gutters(locations) do |gutter, index|
          edge = facts[index]
          output.puts "    #{style.faint(gutter)} #{edge.verb} #{edge.to}"
        end
      end

      # Yields each label right-justified to the widest one, with the frame
      # gutter bar appended, so columns line up like the check output.
      def in_gutters(labels)
        width = labels.map(&:length).max

        labels.each_with_index do |label, index|
          yield "#{label.rjust(width)} │", index
        end
      end

      def line_range(suppression)
        if suppression.end_line == Float::INFINITY
          "#{suppression.start_line}-EOF"
        elsif suppression.start_line == suppression.end_line
          suppression.start_line.to_s
        else
          "#{suppression.start_line}-#{suppression.end_line}"
        end
      end
    end
  end
end
