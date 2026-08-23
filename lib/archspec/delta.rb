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
    # +baseline_diagnostics+ are the current rules evaluated over the baseline
    # graph. Findings among them the receipt did not record were declared
    # since the snapshot: they exist on the old code, so a change that only
    # added the rule declared them rather than caused them, unless it also
    # touched the file.
    def self.between(baseline, current_graph, current_diagnostics, baseline_diagnostics, root:, changed_files:)
      recorded = baseline.receipt.finding_ids.to_set
      on_old_code = baseline_diagnostics.to_h { |diagnostic| [diagnostic.fingerprint(root: root), diagnostic] }
      before_ids = on_old_code.select { |id, diagnostic| recorded.include?(id) || outside_the_rules?(diagnostic) }
      after_ids = current_diagnostics.to_h { |diagnostic| [diagnostic.fingerprint(root: root), diagnostic] }

      appeared = after_ids.reject { |id, _| before_ids.key?(id) }
      declared, introduced = appeared.partition do |id, diagnostic|
        changed_files && on_old_code.key?(id) && !recorded.include?(id) &&
          !changed_files.include?(diagnostic.location.relative_path(root))
      end
      declared = declared.map(&:last)
      introduced = introduced.map(&:last)

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

    # Edges compared by what they connect, not where they sit: a line that
    # moved is the same edge, not one removed and one added.
    def self.edge_difference(before, after)
      before_edges = before.edges.map { |edge| edge_key(edge) }.tally
      after_edges = after.edges.map { |edge| edge_key(edge) }.tally
      added = Hash.new(0)
      removed = Hash.new(0)

      after_edges.each do |key, count|
        extra = count - before_edges.fetch(key, 0)
        added[key.first] += extra if extra.positive?
      end
      before_edges.each do |key, count|
        missing = count - after_edges.fetch(key, 0)
        removed[key.first] += missing if missing.positive?
      end

      [added.sort.to_h, removed.sort.to_h]
    end

    # Parse errors and housekeeping belong to no rule set, so the receipt
    # never records them; they are compared as they stand on both sides.
    def self.outside_the_rules?(diagnostic)
      diagnostic.rule == 'parser.syntax' || diagnostic.rule.start_with?('housekeeping.')
    end

    def self.edge_key(edge)
      [edge.type, edge.from_path, edge.from_constant, edge.to, edge.receiver]
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
