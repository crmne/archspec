#!/usr/bin/env ruby
# frozen_string_literal: true

# Runs ArchSpec against a large open source Rails app pinned to a known
# commit, then compares every diagnostic against the recorded set in
# expected.yml: one entry per diagnostic with the verdict a person gave it.
#
#   ruby test/torture/run.rb discourse
#   ruby test/torture/run.rb mastodon --update
#   ruby test/torture/run.rb fizzy --resolver rubydex
#
# A run fails when the per-rule counts move, when a diagnostic appears that
# the record does not carry, when a true positive disappears, or when the run
# takes longer than the ceiling the record carries. --update records new
# diagnostics as unjudged and keeps every verdict already written; it refuses
# to drop a true positive, which only a hand edit may do, and keeps a ceiling
# once one is written. --resolver declares a second resolver in the copied
# architecture file and prints how its answers converged with the parser's;
# the record stays the parser's, so what appears or vanishes is judged by
# hand. The synthetic app is generated rather than fetched:
# the issue #3 shape, 879 files across 26 packs that all reach each other.

$LOAD_PATH.unshift File.expand_path('../../lib', __dir__)

require 'archspec'
require 'fileutils'
require 'json'
require 'stringio'
require 'yaml'
require_relative 'snapshot'
require_relative 'synthetic'

APPS = {
  'discourse' => {
    url: 'https://github.com/discourse/discourse',
    sha: '4cac48263809d806cee8660c6b1adc6e5d0c9445'
  },
  'fizzy' => {
    url: 'https://github.com/basecamp/fizzy',
    sha: '65bb2f8ff2cc84d9836cd03ba857f3a20552a78a'
  },
  'mastodon' => {
    url: 'https://github.com/mastodon/mastodon',
    sha: '163f96cee4dea23365bff9b433871e68d20d9ee7'
  },
  'synthetic' => {
    generator: TortureSynthetic,
    sha: TortureSynthetic::SHAPE
  }
}.freeze

app_name = ARGV.first
update = ARGV.include?('--update')
resolver = ARGV[ARGV.index('--resolver') + 1] if ARGV.include?('--resolver')
abort "Usage: ruby test/torture/run.rb #{APPS.keys.join('|')} [--update] [--resolver NAME]" unless APPS.key?(app_name)
abort 'the record is the parser\'s; judge a resolver run by hand, never with --update' if update && resolver

app = APPS.fetch(app_name)
repo_root = File.expand_path('../..', __dir__)
checkout = File.join(repo_root, 'tmp', 'torture', app_name)
config_source = File.join(__dir__, app_name, 'Archspec.rb')
expected_path = File.join(__dir__, app_name, 'expected.yml')

if app.key?(:generator)
  FileUtils.rm_rf(checkout)
  app.fetch(:generator).write(checkout)
else
  unless Dir.exist?(File.join(checkout, '.git'))
    FileUtils.mkdir_p(checkout)
    system('git', 'init', '--quiet', checkout, exception: true)
    system('git', '-C', checkout, 'remote', 'add', 'origin', app.fetch(:url), exception: true)
  end

  head = `git -C #{checkout} rev-parse HEAD 2>/dev/null`.strip
  unless head == app.fetch(:sha)
    system('git', '-C', checkout, 'fetch', '--quiet', '--depth', '1', 'origin', app.fetch(:sha), exception: true)
    system('git', '-C', checkout, 'checkout', '--quiet', app.fetch(:sha), exception: true)
  end

  FileUtils.cp(config_source, File.join(checkout, 'Archspec.rb'))
  File.write(File.join(checkout, 'Archspec.rb'), "\nresolver :#{resolver}\n", mode: 'a') if resolver
end

output = StringIO.new
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
status = Dir.chdir(checkout) { ArchSpec::CLI.run(['check', '--format', 'json'], output: output, error: $stderr) }
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

abort "archspec crashed on #{app_name} (exit #{status})" unless [0, 1].include?(status)

report = JSON.parse(output.string)
violations = report.fetch('violations')
counts = TortureSnapshot.counts_for(violations)

puts format('%s @ %s: %d files, %d constants, %d facts in %.1fs',
            app_name, app.fetch(:sha)[0, 12], report.fetch('files'),
            report.fetch('constants'), report.fetch('facts'), elapsed)
counts.each { |rule, count| puts format('  %-40s %d', rule, count) }
puts '  no violations' if counts.empty?
report.fetch('census').fetch('resolvers', {}).each do |name, convergence|
  puts format('  %s: converged %d, parser only %d, %s only %d, disagreed %d (index %s, %.2fs)', name,
              convergence.fetch('converged'), convergence.fetch('parser_only'), name, convergence.fetch('resolver_only'),
              convergence.fetch('disagreed'), convergence.fetch('cache'), convergence.fetch('seconds'))
end

def describe(entry, label)
  format('  %-24s %-28s %s  %s', label, entry.fetch('rule'), entry.fetch('path'), entry.fetch('message'))
end

recorded = File.exist?(expected_path) ? TortureSnapshot.load(expected_path) : nil

if update
  update = TortureSnapshot.update(recorded || {}, violations, sha: app.fetch(:sha), elapsed: elapsed)
  if update.refused?
    puts 'refusing to drop true positives no longer reported; edit the record by hand:'
    recorded.fetch('diagnostics').each { |id, entry| puts describe(entry, id) if update.retained.include?(entry) }
    exit 1
  end
  File.write(expected_path, update.snapshot.to_yaml)
  puts "wrote #{expected_path}"
  exit 0
end

if recorded.nil?
  puts "no snapshot at #{expected_path}; run with --update to record one"
  exit 0
end

abort 'snapshot SHA does not match pinned SHA; re-record with --update' if recorded.fetch('sha') != app.fetch(:sha)

if TortureSnapshot.legacy?(recorded)
  puts 'record carries counts only; run with --update to record each diagnostic'
end

result = TortureSnapshot.compare(recorded, violations, elapsed: elapsed)

unless result.added.empty?
  puts 'added (not in the record):'
  result.added.each { |id, entry| puts describe(entry, id) }
end
unless result.removed.empty?
  puts 'removed (in the record, not reported):'
  result.removed.each { |entry| puts describe(entry, entry.fetch('verdict')) }
end
puts "#{result.improved.size} false positive(s) no longer reported" unless result.improved.empty?

if result.counts_changed
  puts 'MISMATCH against snapshot:'
  (recorded.fetch('rules').keys | counts.keys).sort.each do |rule|
    was = recorded.fetch('rules').fetch(rule, 0)
    now = counts.fetch(rule, 0)
    puts format('  %-40s %d -> %d', rule, was, now) if was != now
  end
end

if result.pass?
  puts 'matches snapshot'
else
  puts "FAILED: #{result.failures.join('; ')}"
  exit 1
end
