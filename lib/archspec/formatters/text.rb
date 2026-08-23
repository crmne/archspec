# frozen_string_literal: true

require 'pathname'

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
        predating, failing = diagnostics.partition(&:predates_rule?)
        style = Style.new(output)
        sources = Hash.new { |hash, path| hash[path] = read_lines(path) }

        failing.each do |diagnostic|
          print_diagnostic(output, style, graph, diagnostic, sources)
        end
        print_predating(output, style, graph, predating)

        if failing.empty?
          output.puts "ArchSpec passed: #{graph.files.size} files, #{graph.constants.size} constants, " \
                      "#{graph.edges.size} facts checked."
        else
          label = failing.size == 1 ? 'architecture violation' : 'architecture violations'
          output.puts style.bold("#{failing.size} #{label} found.")
        end
        output.puts facts_summary(graph)
        output.puts census_summary(graph)
        output.puts dating_summary(graph) if graph.dating_note
      end

      # Findings on lines older than their rule's date: listed under their own
      # heading, one line each, and left out of the count that fails the run.
      def print_predating(output, style, graph, predating)
        return if predating.empty?

        label = predating.size == 1 ? 'finding predates' : 'findings predate'
        output.puts style.bold("#{predating.size} #{label} the rule's since: date, reported, not failed:")
        predating.each do |diagnostic|
          output.puts "  #{diagnostic.location.relative_path(graph.root)}:#{diagnostic.location.line}: " \
                      "#{diagnostic.message} [#{diagnostic.rule}] (since #{diagnostic.since})"
        end
        output.puts
      end

      def dating_summary(graph)
        "since: some findings could not be dated, #{graph.dating_note}; they count as undated"
      end

      # What the run could not see, by cause, so a run the parser barely read
      # never prints the same summary as one it read in full.
      def census_summary(graph)
        clauses = graph.census.clauses
        "could not see: #{clauses.empty? ? 'nothing' : clauses.join(', ')}"
      end

      # The delta against a baseline: what the change introduced, resolved and
      # declared, in that order, each under the same code frame as a plain
      # check. Findings carried from the baseline are counted, and printed only
      # in strict mode, which is what makes the ratchet a ratchet.
      def print_delta(output = $stdout, graph:, diagnostics:, delta:, mode:)
        style = Style.new(output)
        sources = Hash.new { |hash, path| hash[path] = read_lines(path) }

        print_bucket(output, style, graph, delta.introduced, 'introduced', sources)
        print_bucket(output, style, graph, delta.resolved, 'resolved', sources, frames: false)
        print_bucket(output, style, graph, delta.declared, 'declared', sources,
                     note: 'declared by this change, pre-existing in the file')
        print_bucket(output, style, graph, delta.carried, 'carried', sources) if mode == 'strict'

        output.puts style.bold(delta_summary(delta, mode))
        output.puts "baseline: #{baseline_summary(delta)}"
        output.puts "edges: #{edge_summary(delta)}"
        output.puts "changed files: #{delta.changed_files_read ? 'read from the snapshot' : 'not read; every new finding counts as introduced'}"
        output.puts "current: #{diagnostics.size} #{diagnostics.size == 1 ? 'violation' : 'violations'} in all"
        output.puts census_summary(graph)
        output.puts facts_summary(graph)
      end

      def print_bucket(output, style, graph, bucket, label, sources, frames: true, note: nil)
        return if bucket.empty?

        output.puts style.bold("#{label} (#{bucket.size}):")
        output.puts
        bucket.each do |diagnostic|
          if frames
            print_diagnostic(output, style, graph, diagnostic, sources)
            output.puts "  #{style.note('note:')} #{note}\n\n" if note
          else
            output.puts "  #{diagnostic.location.relative_path(graph.root)}: #{diagnostic.message} [#{diagnostic.rule}]"
          end
        end
        output.puts unless frames
      end

      def delta_summary(delta, mode)
        counts = "#{delta.introduced.size} introduced, #{delta.resolved.size} resolved, " \
                 "#{delta.declared.size} declared, #{delta.carried.size} carried"
        if delta.failed?(mode)
          "Architecture regressed (#{mode}): #{counts}."
        else
          "Architecture held (#{mode}): #{counts}."
        end
      end

      def baseline_summary(delta)
        receipt = delta.receipt
        return 'no commit recorded' unless receipt.commit

        "#{receipt.commit[0, 12]}#{' (dirty)' if receipt.dirty}"
      end

      def edge_summary(delta)
        return 'unchanged' if delta.edges_added.empty? && delta.edges_removed.empty?

        parts = delta.edges_added.map { |type, count| "+#{count} #{type}" } +
                delta.edges_removed.map { |type, count| "-#{count} #{type}" }
        parts.join(', ')
      end

      # Names the facts files merged into the graph, or says the directory was
      # absent, so a run without facts never reads like a run that agreed.
      def facts_summary(graph)
        directory = Pathname(graph.facts_directory.to_s).relative_path_from(Pathname(graph.root)).to_s
        if graph.facts_files.empty?
          state = graph.facts_present? ? 'empty' : 'absent'
          return "facts: none (#{directory}/ #{state})"
        end

        merged = graph.facts_files.map do |file|
          label = file.entries == 1 ? 'entry' : 'entries'
          "#{file.relative_path} (#{file.producer} #{file.producer_version}, #{file.entries} #{label})"
        end
        "facts: #{merged.join(', ')}"
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
        output.puts "  #{style.note('reason:')} #{diagnostic.reason}" if diagnostic.reason
        output.puts "  #{style.note('action:')} #{diagnostic.suggested_action}" if diagnostic.suggested_action
        output.puts "  #{style.note('since:')} #{since_for(diagnostic)}" if diagnostic.age == :unknown
        output.puts
      end

      def since_for(diagnostic)
        "#{diagnostic.since}, this line could not be dated, so the finding counts as undated"
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

        return note if diagnostic.confidence == :high

        detail = [diagnostic.confidence, diagnostic.caveat].compact.join(', ')
        "#{note} (confidence: #{detail})"
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
