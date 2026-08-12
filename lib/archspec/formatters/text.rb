# frozen_string_literal: true

module ArchSpec
  module Formatters
    # Prints diagnostics the way clang and herb do: a severity header with the
    # rule id, the location, a code frame with the offending span underlined,
    # and the evidence as a note.
    #
    #   [error] models must not depend on controllers [dependencies.forbid]
    #
    #   app/models/user.rb:3:3
    #
    #       2 │ class User
    #     → 3 │   UsersController
    #         │   ^~~~~~~~~~~~~~~
    #       4 │ end
    #
    #     note: User references UsersController
    #
    # Output to a terminal is colored; a non-TTY or a NO_COLOR environment
    # disables the colors.
    module Text
      CONTEXT_LINES = 1

      module_function

      def print(output = $stdout, graph:, diagnostics:)
        if diagnostics.empty?
          output.puts "ArchSpec passed: #{graph.files.size} files, #{graph.constants.size} constants, " \
                      "#{graph.edges.size} facts checked."
          return
        end

        style = Style.new(output)
        sources = Hash.new { |hash, path| hash[path] = read_lines(path) }

        diagnostics.each do |diagnostic|
          print_diagnostic(output, style, graph, diagnostic, sources)
        end

        label = diagnostics.size == 1 ? 'architecture violation' : 'architecture violations'
        output.puts style.bold("#{diagnostics.size} #{label} found.")
      end

      def print_diagnostic(output, style, graph, diagnostic, sources)
        location = diagnostic.location
        relative = location.relative_path(graph.root)

        output.puts "#{style.severity('[error]')} #{style.bold(diagnostic.message)} #{style.faint("[#{diagnostic.rule}]")}"
        output.puts
        output.puts "#{relative}:#{location.line}:#{location.column}"
        print_frame(output, style, location, sources[location.path])

        if (note = note_for(diagnostic, relative))
          output.puts
          output.puts "  #{style.note('note:')} #{note}"
        end
        output.puts
      end

      def print_frame(output, style, location, lines)
        target = lines[location.line - 1]
        return unless target

        output.puts
        first = [location.line - CONTEXT_LINES, 1].max
        last = [location.line + CONTEXT_LINES, lines.size].min
        width = last.to_s.length

        (first..last).each do |number|
          text = lines[number - 1]
          if number == location.line
            output.puts "  #{style.marker('→')} #{style.faint("#{number.to_s.rjust(width)} │")} #{text}"
            output.puts "    #{style.faint("#{' ' * width} │")} #{style.marker(underline(location, target))}"
          else
            output.puts "    #{style.faint("#{number.to_s.rjust(width)} │")} #{text}"
          end
        end
      end

      # The evidence as a note, or nil when it would only repeat the location
      # shown above it, as parse-error evidence does.
      def note_for(diagnostic, relative)
        note = diagnostic.evidence.to_s
        return if note.empty? || note == relative

        note = "#{note} (confidence: #{diagnostic.confidence})" unless diagnostic.confidence == :high
        note
      end

      def underline(location, text)
        span =
          if location.end_line == location.line
            location.end_column - location.column
          else
            text.length - location.column + 1
          end
        span = span.clamp(1, [text.length - location.column + 1, 1].max)

        "#{' ' * (location.column - 1)}^#{'~' * (span - 1)}"
      end

      def read_lines(path)
        return [] unless File.file?(path)

        File.readlines(path, chomp: true).map { |line| line.scrub.tr("\t", ' ') }
      rescue SystemCallError
        []
      end
    end
  end
end
