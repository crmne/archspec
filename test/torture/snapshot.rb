# frozen_string_literal: true

require 'yaml'

# The recorded set of diagnostics for a pinned torture app: one entry per
# diagnostic keyed by its todo fingerprint, each carrying a verdict a person
# wrote. The per-rule counts are derived from the entries and checked on every
# run, so the gate a release relied on only gets stronger. Two violations at
# different lines of one file can share a fingerprint; the counts stay per
# violation, as the release gate always counted them, while the entries are
# per fingerprint. The record also carries a ceiling in seconds: a run over
# it is a regression, and the ceiling is wide enough that only an order of
# magnitude trips it, never a slow runner.
module TortureSnapshot
  VERDICTS = %w[true_positive false_positive unjudged].freeze
  FIELDS = %w[rule path message evidence].freeze
  CEILING_FACTOR = 10
  CEILING_FLOOR = 30

  Update = Struct.new(:snapshot, :retained, keyword_init: true) do
    def refused?
      !retained.empty?
    end
  end

  Result = Struct.new(:counts_changed, :added, :removed, :improved, :over_ceiling, keyword_init: true) do
    def failures
      failures = []
      failures << 'per-rule counts moved' if counts_changed
      failures << over_ceiling if over_ceiling
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
    raise ArgumentError, "#{path}: expected a mapping with sha and rules" unless data.is_a?(Hash) && data.key?('sha') && data['rules'].is_a?(Hash)

    entries = data.fetch('diagnostics', {})
    raise ArgumentError, "#{path}: diagnostics must be a mapping keyed by fingerprint" unless entries.is_a?(Hash)

    entries.each do |id, entry|
      raise ArgumentError, "#{path}: #{id} is not a mapping" unless entry.is_a?(Hash)

      missing = (FIELDS + ['verdict']).reject { |field| entry.key?(field) }
      raise ArgumentError, "#{path}: #{id} is missing #{missing.join(', ')}" unless missing.empty?

      verdict = entry.fetch('verdict')
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

  def compare(recorded, violations, elapsed: nil)
    live = entries_for(violations)
    counts_changed = recorded.fetch('rules') != counts_for(violations)
    over = over_ceiling(recorded, elapsed)
    if legacy?(recorded)
      return Result.new(counts_changed: counts_changed, added: {}, removed: [], improved: [], over_ceiling: over)
    end

    recorded_entries = recorded.fetch('diagnostics')
    added = live.reject { |id, _| recorded_entries.key?(id) }
    removed = recorded_entries.reject { |id, _| live.key?(id) }
    Result.new(
      counts_changed: counts_changed,
      added: added,
      removed: removed.values,
      improved: removed.values.select { |entry| entry.fetch('verdict') == 'false_positive' },
      over_ceiling: over
    )
  end

  def over_ceiling(recorded, elapsed)
    ceiling = recorded['seconds']
    return if ceiling.nil? || elapsed.nil? || elapsed <= ceiling

    format('took %.1fs, over the %ds ceiling', elapsed, ceiling)
  end

  def ceiling_for(recorded, elapsed)
    recorded['seconds'] || [(elapsed.to_f * CEILING_FACTOR).ceil, CEILING_FLOOR].max
  end

  def update(recorded, violations, sha:, elapsed: nil)
    live = entries_for(violations)
    previous = recorded.fetch('diagnostics', {})
    kept = previous.select { |id, entry| live.key?(id) || entry.fetch('verdict') == 'true_positive' }
    retained_true_positives = kept.reject { |id, _| live.key?(id) }
    return Update.new(snapshot: nil, retained: retained_true_positives.values) unless retained_true_positives.empty?

    entries = live.to_h do |id, entry|
      judged = previous.fetch(id, {})
      merged = entry.merge('verdict' => judged.fetch('verdict', 'unjudged'))
      merged['note'] = judged['note'] if judged.key?('note')
      [id, merged]
    end
    snapshot = { 'sha' => sha, 'seconds' => ceiling_for(recorded, elapsed), 'rules' => counts_for(violations),
                 'diagnostics' => entries }
    Update.new(snapshot: snapshot, retained: [])
  end

  def legacy?(recorded)
    !recorded.key?('diagnostics')
  end
end
