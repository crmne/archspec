# frozen_string_literal: true

require_relative 'value_object'

module ArchSpec
  # What a change did, read as the difference between the diagnostics of a
  # baseline snapshot and of the working tree. Introduced findings are new;
  # resolved ones went away; declared ones are breaches of a rule that did not
  # exist when the baseline was taken, in a file the change did not touch, so
  # the change declared them rather than caused them. Carried findings are
  # present on both sides and only a strict run reports them.
  Delta = ValueObject.define(
    :receipt,
    :introduced,
    :resolved,
    :declared,
    :carried,
    :edges_added,
    :edges_removed,
    :changed_files_read
  ) do
    def self.between(baseline, current_graph, current_diagnostics, baseline_diagnostics, root:, changed_files:)
      baseline_rules = baseline.receipt.rule_ids.to_set
      before = baseline_diagnostics.select { |diagnostic| baseline_rule?(diagnostic, baseline_rules) }
      before_ids = before.to_h { |diagnostic| [diagnostic.fingerprint(root: root), diagnostic] }
      after_ids = current_diagnostics.to_h { |diagnostic| [diagnostic.fingerprint(root: root), diagnostic] }

      appeared = after_ids.reject { |id, _| before_ids.key?(id) }.values
      declared, introduced = appeared.partition do |diagnostic|
        changed_files && !baseline_rules.include?(diagnostic.rule) &&
          !changed_files.include?(diagnostic.location.relative_path(root))
      end

      added, removed = edge_difference(baseline.graph, current_graph)

      new(
        receipt: baseline.receipt,
        introduced: introduced,
        resolved: before_ids.reject { |id, _| after_ids.key?(id) }.values,
        declared: declared,
        carried: after_ids.select { |id, _| before_ids.key?(id) }.values,
        edges_added: added,
        edges_removed: removed,
        changed_files_read: !changed_files.nil?
      )
    end

    # Diagnostics a baseline can stand behind: those of rules it knew, plus
    # parse errors, which belong to no rule set.
    def self.baseline_rule?(diagnostic, baseline_rules)
      diagnostic.rule == 'parser.syntax' || baseline_rules.include?(diagnostic.rule)
    end

    def self.edge_difference(before, after)
      before_edges = before.edges.tally
      after_edges = after.edges.tally
      added = Hash.new(0)
      removed = Hash.new(0)

      after_edges.each do |edge, count|
        extra = count - before_edges.fetch(edge, 0)
        added[edge.type] += extra if extra.positive?
      end
      before_edges.each do |edge, count|
        missing = count - after_edges.fetch(edge, 0)
        removed[edge.type] += missing if missing.positive?
      end

      [added.sort.to_h, removed.sort.to_h]
    end

    def failed?(mode)
      case mode
      when 'ratchet' then introduced.any?
      when 'strict' then introduced.any? || carried.any?
      else false
      end
    end

    def self.modes
      %w[ratchet advisory strict]
    end

    def scoped
      with(
        introduced: yield(introduced),
        resolved: yield(resolved),
        declared: yield(declared),
        carried: yield(carried)
      )
    end
  end
end
