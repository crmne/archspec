# frozen_string_literal: true

require 'yaml'

# The recorded set of diagnostics for a pinned torture app: one entry per
# diagnostic keyed by its todo fingerprint, each carrying a verdict a person
# wrote. The per-rule counts are derived from the entries and checked on every
# run, so the gate a release relied on only gets stronger. Two violations at
# different lines of one file can share a fingerprint; the counts stay per
# violation, as the release gate always counted them, while the entries are
# per fingerprint.
module TortureSnapshot
  VERDICTS = %w[true_positive false_positive unjudged].freeze
  FIELDS = %w[rule path message evidence].freeze

  Result = Struct.new(:counts_changed, :added, :removed, :improved, keyword_init: true) do
    def failures
      failures = []
      failures << 'per-rule counts moved' if counts_changed
      failures << "#{added.size} diagnostic(s) not in the record" unless added.empty?
      lost = removed.select { |entry| entry.fetch('verdict') == 'true_positive' }
      failures << "#{lost.size} true positive(s) gone" unless lost.empty?
      failures
    end

    def pass?
      failures.empty?
    end
  end

  module_function

  def load(path)
    data = YAML.safe_load_file(path)
    entries = data.fetch('diagnostics', {})
    entries.each do |id, entry|
      verdict = entry.fetch('verdict', nil)
      next if VERDICTS.include?(verdict)

      raise ArgumentError, "#{path}: #{id} has verdict #{verdict.inspect}, expected one of #{VERDICTS.join(', ')}"
    end
    data
  end

  def entries_for(violations)
    violations.each_with_object({}) do |violation, entries|
      entries[violation.fetch('id')] = FIELDS.to_h { |field| [field, violation.fetch(field)] }
    end.sort.to_h
  end

  def counts_for(violations)
    violations.group_by { |violation| violation.fetch('rule') }.transform_values(&:size).sort.to_h
  end

  def compare(recorded, violations)
    live = entries_for(violations)
    counts_changed = recorded.fetch('rules') != counts_for(violations)
    return Result.new(counts_changed: counts_changed, added: {}, removed: [], improved: []) if legacy?(recorded)

    recorded_entries = recorded.fetch('diagnostics')
    added = live.reject { |id, _| recorded_entries.key?(id) }
    removed = recorded_entries.reject { |id, _| live.key?(id) }
    Result.new(
      counts_changed: counts_changed,
      added: added,
      removed: removed.values,
      improved: removed.values.select { |entry| entry.fetch('verdict') == 'false_positive' }
    )
  end

  def update(recorded, violations, sha:)
    live = entries_for(violations)
    previous = recorded.fetch('diagnostics', {})
    kept = previous.select { |id, entry| live.key?(id) || entry.fetch('verdict') == 'true_positive' }
    retained_true_positives = kept.reject { |id, _| live.key?(id) }
    return [nil, retained_true_positives.values] unless retained_true_positives.empty?

    entries = live.to_h do |id, entry|
      judged = previous.fetch(id, {})
      merged = entry.merge('verdict' => judged.fetch('verdict', 'unjudged'))
      merged['note'] = judged['note'] if judged.key?('note')
      [id, merged]
    end
    [{ 'sha' => sha, 'rules' => counts_for(violations), 'diagnostics' => entries }, []]
  end

  def legacy?(recorded)
    !recorded.key?('diagnostics')
  end
end
