# frozen_string_literal: true

module ArchSpec
  module Evaluator
    extend self

    UNUSED_SUPPRESSION_RULE = 'housekeeping.unused_suppression'
    STALE_TODO_RULE = 'housekeeping.stale_todo'

    def evaluate(definition, graph, todo: Todo.empty, housekeeping: false)
      declare_public_names(definition, graph)
      diagnostics = parser_diagnostics(graph) + definition.rules.flat_map { |rule| rule.evaluate(graph) }

      # Deduplicate before rejecting. One statement can raise several diagnostics
      # that differ only in evidence, because `include Foo` is both an includes
      # edge and a constant reference. Todo entries are matched on evidence, so
      # rejecting first would drop the recorded diagnostic and report its
      # surviving sibling as new.
      diagnostics = diagnostics
        .sort_by { |d| [d.location.path, d.location.line, d.rule, d.message, d.evidence] }
        .uniq { |d| [d.rule, d.message, d.location.path, d.location.line] }

      matched_suppressions = Set.new
      matched_todo_ids = Set.new
      reported = diagnostics.reject do |diagnostic|
        suppressions = graph.suppressions_matching(diagnostic)
        matched_suppressions.merge(suppressions)
        todo_id = todo.id_for(diagnostic)
        matched_todo_ids.add(todo_id) if todo_id
        suppressions.any? || todo_id
      end

      unused = graph.suppressions.reject { |suppression| matched_suppressions.include?(suppression) }
      stale = todo.entries.reject { |entry| matched_todo_ids.include?(entry.id) }
      graph.record_housekeeping(unused_suppressions: unused.size, stale_todo_entries: stale.size)

      reported = reported.map { |diagnostic| doubt_near_dynamic_features(graph, diagnostic) }
      reported = date_against_rules(graph, reported)
      reported += housekeeping_diagnostics(graph, todo, unused, stale) if housekeeping
      reported
    end

    private

    # Public declarations are read off the rules that make them, before any
    # rule runs, so a cut reported by another rule can name them.
    def declare_public_names(definition, graph)
      definition.rules.each do |rule|
        next unless rule.respond_to?(:public_names)

        graph.declare_public(rule.source, rule.public_names(graph))
      end
    end

    # A finding from a dated rule asks git when its witness line last changed.
    # Only dated rules pay for the question, and one cause for an unanswerable
    # line is kept on the graph so the run prints it once.
    def date_against_rules(graph, diagnostics)
      return diagnostics if diagnostics.none?(&:since)

      ages = LineAge.new(graph.root)
      dated = diagnostics.map do |diagnostic|
        next diagnostic unless diagnostic.since

        diagnostic.aged(ages.verdict(diagnostic.location.path, diagnostic.location.line, diagnostic.since))
      end
      graph.dating_note = ages.note
      dated
    end

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

    # A finding inside a constant that uses a dynamic feature is less certain
    # than the parser can say: the feature may define or reach what the rule
    # could not see. The scope is the constant the finding sits in, not the
    # file, so one `send` in a callback does not cloud an unrelated class.
    def doubt_near_dynamic_features(graph, diagnostic)
      return diagnostic unless diagnostic.confidence == :high

      constant = graph.constant_enclosing(diagnostic.location)
      return diagnostic if constant.nil?

      features = graph.dynamic_features_for(constant.name, diagnostic.location.path)
      return doubt_near_disagreements(graph, diagnostic, constant) if features.empty?

      feature = features.min_by { |edge| edge.location.line }
      diagnostic.doubted("#{feature.to} at line #{feature.location.line}")
    end

    # A finding inside a constant where two resolvers read a reference
    # differently rests on a graph one of them would have drawn otherwise.
    def doubt_near_disagreements(graph, diagnostic, constant)
      return diagnostic if graph.resolvers.empty?

      disagreement = graph.disagreements_for(constant.name, diagnostic.location.path).first
      return diagnostic unless disagreement

      diagnostic.doubted("the resolvers disagree: parser #{disagreement.name}, #{graph.resolvers.join(', ')} #{disagreement.other}")
    end

    def housekeeping_diagnostics(graph, todo, unused, stale)
      unused.map do |suppression|
        file = graph.files.values.find { |candidate| candidate.suppressions.include?(suppression) }
        Diagnostic.new(
          rule: UNUSED_SUPPRESSION_RULE,
          message: "suppression of #{suppression.rule || 'all rules'} matched no diagnostic",
          location: SourceLocation.point(file.path, suppression.start_line, 1),
          evidence: "#{file.relative_path}:#{suppression.start_line} suppresses #{suppression.rule || '*'}"
        )
      end + stale.map do |entry|
        Diagnostic.new(
          rule: STALE_TODO_RULE,
          message: "todo entry #{entry.id} matched no diagnostic",
          location: SourceLocation.point(todo.path, 1, 1),
          evidence: "#{entry.id} #{entry.rule} #{entry.path}".strip
        )
      end
    end
  end
end
