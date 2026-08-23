# frozen_string_literal: true

require 'test_helper'
require 'tmpdir'
require_relative 'torture/snapshot'

class TortureSnapshotTest < Minitest::Test
  SHA = 'abc123'

  def test_entries_are_keyed_by_fingerprint_and_sorted
    entries = TortureSnapshot.entries_for([violation('b'), violation('a')])

    assert_equal %w[a b], entries.keys
    assert_equal TortureSnapshot::FIELDS, entries.fetch('a').keys
  end

  def test_update_records_new_diagnostics_as_unjudged_and_keeps_verdicts
    recorded = record('a' => 'true_positive', 'b' => 'false_positive')
    recorded.fetch('diagnostics').fetch('a')['note'] = 'real'
    update = TortureSnapshot.update(recorded, [violation('a'), violation('b'), violation('c')], sha: SHA)
    snapshot = update.snapshot

    refute update.refused?
    assert_equal 'true_positive', snapshot.dig('diagnostics', 'a', 'verdict')
    assert_equal 'real', snapshot.dig('diagnostics', 'a', 'note')
    assert_equal 'false_positive', snapshot.dig('diagnostics', 'b', 'verdict')
    assert_equal 'unjudged', snapshot.dig('diagnostics', 'c', 'verdict')
    assert_equal({ 'dependencies.forbid' => 3 }, snapshot.fetch('rules'))
  end

  def test_update_drops_unjudged_and_false_positives_but_refuses_true_positives
    recorded = record('a' => 'unjudged', 'b' => 'false_positive')
    update = TortureSnapshot.update(recorded, [], sha: SHA)

    refute update.refused?
    assert_empty update.snapshot.fetch('diagnostics')

    recorded = record('a' => 'true_positive')
    update = TortureSnapshot.update(recorded, [], sha: SHA)

    assert update.refused?
    assert_nil update.snapshot
    assert_equal ['true_positive'], update.retained.map { |entry| entry.fetch('verdict') }
  end

  def test_update_migrates_a_counts_only_record
    legacy = { 'sha' => SHA, 'rules' => { 'dependencies.forbid' => 1 } }
    snapshot = TortureSnapshot.update(legacy, [violation('a')], sha: SHA).snapshot

    assert_equal 'unjudged', snapshot.dig('diagnostics', 'a', 'verdict')
    assert_equal legacy.fetch('rules'), snapshot.fetch('rules')
  end

  def test_compare_fails_on_unrecorded_additions_and_lost_true_positives
    recorded = record('a' => 'true_positive', 'b' => 'false_positive')

    result = TortureSnapshot.compare(recorded, [violation('a'), violation('b')])
    assert result.pass?

    result = TortureSnapshot.compare(recorded, [violation('a'), violation('c')])
    refute result.pass?
    assert_equal %w[c], result.added.keys

    result = TortureSnapshot.compare(recorded, [violation('b')])
    refute result.pass?
    assert_includes result.failures, '1 true positive(s) gone'
  end

  def test_counts_stay_per_violation_when_two_share_a_fingerprint
    violations = [violation('a').merge('line' => 3), violation('a').merge('line' => 9)]
    snapshot = TortureSnapshot.update({}, violations, sha: SHA).snapshot

    assert_equal({ 'dependencies.forbid' => 2 }, snapshot.fetch('rules'))
    assert_equal %w[a], snapshot.fetch('diagnostics').keys
  end

  def test_compare_treats_a_vanished_false_positive_as_an_improvement
    recorded = record('a' => 'true_positive', 'b' => 'false_positive', 'c' => 'unjudged')
    recorded['rules'] = { 'dependencies.forbid' => 1 }

    result = TortureSnapshot.compare(recorded, [violation('a')])

    assert result.pass?
    assert_equal 1, result.improved.size
  end

  def test_compare_checks_counts_only_against_a_counts_only_record
    legacy = { 'sha' => SHA, 'rules' => { 'dependencies.forbid' => 1 } }

    assert TortureSnapshot.compare(legacy, [violation('a')]).pass?
    refute TortureSnapshot.compare(legacy, []).pass?
  end

  def test_load_rejects_an_unknown_verdict
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'expected.yml')
      File.write(path, record('a' => 'maybe').to_yaml)

      assert_raises(ArgumentError) { TortureSnapshot.load(path) }
    end
  end

  private

  def violation(id, rule: 'dependencies.forbid')
    { 'id' => id, 'rule' => rule, 'path' => "app/#{id}.rb", 'message' => "#{id} breaks", 'evidence' => "references #{id}", 'line' => 3 }
  end

  def record(verdicts)
    entries = verdicts.to_h do |id, verdict|
      [id, TortureSnapshot.entries_for([violation(id)]).fetch(id).merge('verdict' => verdict)]
    end
    { 'sha' => SHA, 'rules' => TortureSnapshot.counts_for(verdicts.keys.map { |id| violation(id) }), 'diagnostics' => entries }
  end

  def test_load_names_the_file_and_entry_when_the_shape_is_wrong
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'expected.yml')
      File.write(path, { 'sha' => SHA, 'rules' => {}, 'diagnostics' => { 'a' => { 'rule' => 'x' } } }.to_yaml)
      error = assert_raises(ArgumentError) { TortureSnapshot.load(path) }
      assert_match(/expected\.yml: a is missing path, message, evidence, verdict/, error.message)

      File.write(path, { 'sha' => SHA, 'rules' => {}, 'diagnostics' => [] }.to_yaml)
      error = assert_raises(ArgumentError) { TortureSnapshot.load(path) }
      assert_match(/diagnostics must be a mapping/, error.message)
    end
  end
end
