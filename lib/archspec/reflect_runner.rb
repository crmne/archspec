# frozen_string_literal: true

# Executed only by `archspec reflect`, once per producer, in its own process.
require_relative '../archspec'

begin
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  definition, root = ArchSpec::CLI.load_definition(ENV.fetch('ARCHSPEC_REFLECTION_CONFIG'))
  producer = ArchSpec::Producer.load(ENV.fetch('ARCHSPEC_PRODUCER'), definition)
  document = producer.run(definition, root)
  output = File.join(File.expand_path(definition.facts_path, root), "#{producer.name}.yml")
  ArchSpec::Facts.write(output, document)
  labels = { 'references' => 'reference', 'methods' => 'method', 'mixins' => 'mixin', 'gaps' => 'gap',
             'resolves' => 'resolved gap' }
  counts = labels.filter_map do |key, label|
    size = key == 'methods' ? document[key].sum { |entry| entry['names'].size } : document[key].size
    "#{size} #{label}#{'s' unless size == 1}" if size.positive?
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  summary = counts.empty? ? 'no facts' : counts.join(', ')
  puts format('Updated %<path>s: %<summary>s (%<seconds>.1fs)',
    path: Pathname(output).relative_path_from(Pathname(root)), summary: summary, seconds: elapsed)
  document['gaps'].each { |gap| puts "  gap: #{gap['path']}:#{gap['line']} #{gap['message']}" }
rescue ArchSpec::Error => error
  warn error.message
  exit 1
end
