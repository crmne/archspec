# frozen_string_literal: true

require 'pathname'

module ArchSpec
  module Formatters
    # Prints one GitHub Actions workflow command per finding, so a job step
    # that runs <tt>archspec check --format github</tt> annotates the pull
    # request diff on the offending span without a token or an upload.
    #
    #   ::error file=app/models/user.rb,line=3,col=3,endLine=3,endColumn=18,title=dependencies.forbid::models must not depend on controllers. ...
    #
    # Failing findings are errors, findings older than their rule's date are
    # warnings, and the facts, census and dating lines are notices, so the
    # annotations say what was not seen as well as what was found.
    module GitHub
      module_function

      def print(output = $stdout, graph:, diagnostics:)
        diagnostics.each do |diagnostic|
          output.puts command(diagnostic.predates_rule? ? 'warning' : 'error', graph, diagnostic)
        end
        print_notices(output, graph)
      end

      # The buckets map to the severity each mode gives them: introduced
      # findings fail, declared ones warn, resolved ones are good news, and
      # carried ones are warnings only when strict mode would fail on them.
      def print_delta(output = $stdout, graph:, diagnostics:, delta:, mode:)
        delta.introduced.each do |diagnostic|
          output.puts command(diagnostic.predates_rule? ? 'warning' : 'error', graph, diagnostic)
        end
        delta.declared.each do |diagnostic|
          output.puts command('warning', graph, diagnostic, title: "#{diagnostic.rule} declared")
        end
        delta.resolved.each do |diagnostic|
          output.puts command('notice', graph, diagnostic, title: "#{diagnostic.rule} resolved")
        end
        if mode == 'strict'
          delta.carried.each do |diagnostic|
            output.puts command('warning', graph, diagnostic, title: "#{diagnostic.rule} carried")
          end
        end
        print_notices(output, graph)
      end

      def command(level, graph, diagnostic, title: diagnostic.rule)
        location = diagnostic.location
        properties = {
          file: location.relative_path(graph.root),
          line: location.line,
          col: location.column,
          endLine: location.end_line,
          endColumn: location.end_column,
          title: title
        }
        "::#{level} #{properties.map { |key, value| "#{key}=#{escape_property(value.to_s)}" }.join(',')}" \
          "::#{escape_data(message_for(diagnostic))}"
      end

      def message_for(diagnostic)
        sentences = [diagnostic.message]
        sentences << "Reason: #{diagnostic.reason}" if diagnostic.reason
        sentences << "Action: #{diagnostic.suggested_action}" if diagnostic.suggested_action
        sentences << "Predates the rule's since: date (#{diagnostic.dated})." if diagnostic.predates_rule?
        sentences.map { |sentence| sentence.end_with?('.') ? sentence : "#{sentence}." }.join(' ')
      end

      def print_notices(output, graph)
        output.puts notice(facts_line(graph))
        output.puts notice(census_line(graph))
        output.puts notice(dating_line(graph)) if graph.dating_note
      end

      def notice(text)
        "::notice title=archspec::#{escape_data(text)}"
      end

      def facts_line(graph)
        directory = Pathname(graph.facts_directory.to_s).relative_path_from(Pathname(graph.root)).to_s
        return "facts: none (#{directory}/ #{graph.facts_present? ? 'empty' : 'absent'})" if graph.facts_files.empty?

        merged = graph.facts_files.map do |file|
          "#{file.relative_path} (#{file.producer} #{file.producer_version}, #{file.entries} entries)"
        end
        "facts: #{merged.join(', ')}"
      end

      def census_line(graph)
        clauses = graph.census.clauses
        "could not see: #{clauses.empty? ? 'nothing' : clauses.join(', ')}"
      end

      def dating_line(graph)
        "since: some findings could not be dated, #{graph.dating_note}; they count as undated"
      end

      # The command grammar keeps properties and data on one line: the
      # characters it reads are percent-encoded the way the runner decodes them.
      def escape_data(text)
        text.gsub('%', '%25').gsub("\r", '%0D').gsub("\n", '%0A')
      end

      def escape_property(text)
        escape_data(text).gsub(':', '%3A').gsub(',', '%2C')
      end
    end
  end
end
