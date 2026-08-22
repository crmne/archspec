# frozen_string_literal: true

require 'digest'
require 'open3'
require 'optparse'
require 'pathname'

module ArchSpec
  # The <tt>archspec</tt> command line. Backs the +exe/archspec+ executable and
  # dispatches the +init+, +check+, +explain+, and +version+ subcommands.
  #
  #   archspec init
  #   archspec check [PATHS...] [--config PATH] [--format text|json] [--update-todo] [--housekeeping]
  #   archspec check --baseline [DIR] [--mode ratchet|advisory|strict]
  #   archspec snapshot [--config PATH] [--output DIR]
  #   archspec explain PATH_OR_CONSTANT
  #   archspec reflect [--config PATH] [--output PATH] [--static]
  #
  # #run returns the process exit status: 0 when clean, 1 when violations are
  # found, 3 when a baseline could not be compared.
  module CLI
    extend self

    CONFIG_FILE = 'Archspec.rb'
    USAGE_ERROR_STATUS = 64
    DECLINED_STATUS = 3
    TEMPLATE = <<~RUBY
      architecture :rails
    RUBY

    class UsageError < Error; end

    def run(argv, output: $stdout, error: $stderr)
      argv = argv.dup
      command = argv.shift || 'check'

      case command
      when 'help', '--help', '-h'
        help(argv, output)
      when 'init'
        init(argv, output)
      when 'check'
        check(argv, output)
      when 'snapshot'
        snapshot(argv, output)
      when 'explain'
        explain(argv, output)
      when 'reflect'
        reflect(argv, output)
      when 'version', '--version', '-v'
        raise UsageError, "unexpected argument: #{argv.first}" if argv.any?

        output.puts ArchSpec::VERSION
        0
      else
        raise UsageError, "unknown command: #{command}"
      end
    rescue OptionParser::ParseError, UsageError => e
      error.puts "archspec: error: #{e.message}"
      error.puts usage(command)
      USAGE_ERROR_STATUS
    rescue Error => e
      error.puts "archspec: error: #{e.message}"
      1
    end

    private

    def help(argv, output)
      subject = argv.shift
      raise UsageError, "unexpected argument: #{argv.first}" if argv.any?
      if subject && !%w[init check snapshot explain reflect version].include?(subject)
        raise UsageError, "unknown command: #{subject}"
      end

      output.puts usage(subject)
      0
    end

    def init(argv, output)
      options = { force: false, help: false }
      parser = OptionParser.new do |opts|
        opts.banner = usage('init').strip
        opts.on('--force', 'Overwrite an existing file') { options[:force] = true }
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
      end
      parser.parse!(argv)

      if options[:help]
        output.puts parser
        return 0
      end

      raise UsageError, "unexpected argument: #{argv[1]}" if argv.length > 1

      path = argv.shift || CONFIG_FILE

      if File.exist?(path) && !options[:force]
        raise Error, "#{path} already exists (use --force to overwrite)"
      end

      File.write(path, TEMPLATE)
      output.puts "Created #{path}"
      0
    rescue SystemCallError => e
      raise Error, "could not create #{path}: #{e.message}"
    end

    def check(argv, output)
      options = {
        config: CONFIG_FILE,
        format: 'text',
        update_todo: false,
        housekeeping: false,
        baseline: nil,
        mode: nil,
        help: false
      }

      parser = OptionParser.new do |opts|
        opts.banner = usage('check').strip
        opts.on('--config PATH', 'Use a different architecture file') { |value| options[:config] = value }
        opts.on('--format FORMAT', 'Output text or json') { |value| options[:format] = value }
        opts.on('--update-todo', 'Replace the configured todo with current violations') do
          options[:update_todo] = true
        end
        opts.on('--housekeeping', 'Report unused suppressions and stale todo entries as violations') do
          options[:housekeeping] = true
        end
        opts.on('--baseline [DIR]', 'Grade the change against a snapshot (default .archspec)') do |value|
          options[:baseline] = value || Snapshot::DEFAULT_DIRECTORY
        end
        opts.on('--mode MODE', 'With a baseline: ratchet, advisory, or strict') { |value| options[:mode] = value }
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
      end
      parser.parse!(argv)

      if options[:help]
        output.puts parser
        return 0
      end

      raise Error, 'cannot combine --update-todo with path arguments' if options[:update_todo] && argv.any?
      raise Error, 'cannot combine --update-todo with --housekeeping' if options[:update_todo] && options[:housekeeping]
      raise Error, 'cannot combine --update-todo with --baseline' if options[:update_todo] && options[:baseline]
      raise UsageError, '--mode needs --baseline' if options[:mode] && !options[:baseline]

      mode = options[:mode] || 'ratchet'
      raise UsageError, "unknown mode: #{mode.inspect}" unless Delta.modes.include?(mode)

      formatter = formatter_for(options[:format])
      definition, root = load_definition(options[:config])
      graph = analyze_for_check(definition, root, argv, options)
      todo_path = todo_path_for(definition, root)
      todo = options[:update_todo] ? Todo.empty(root: root) : Todo.load(todo_path, root: root)
      diagnostics = Evaluator.evaluate(definition, graph, todo: todo, housekeeping: options[:housekeeping])

      if options[:baseline]
        return check_against_baseline(options, argv, output, formatter, definition, root, graph, todo, diagnostics,
                                      mode)
      end

      diagnostics = scope_to_paths(diagnostics, argv, root)

      if options[:update_todo]
        unless todo_path
          raise Error,
                "no todo configured; add `todo \"archspec_todo.yml\"` to #{options[:config]}"
        end

        # Syntax errors are never an accepted baseline; they must be fixed.
        accepted = diagnostics.reject { |diagnostic| diagnostic.rule == 'parser.syntax' }
        Todo.write(todo_path, accepted, root: root)
        label = accepted.size == 1 ? 'violation' : 'violations'
        output.puts "Updated #{Pathname(todo_path).relative_path_from(Pathname(root))} with #{accepted.size} #{label}."
        return 0
      end

      formatter.print(output, graph: graph, diagnostics: diagnostics)
      diagnostics.reject(&:predates_rule?).empty? ? 0 : 1
    end

    # A path-scoped run over a snapshot of the same tree re-reads only the
    # named paths; every other file's facts come from the snapshot. It happens
    # whenever the snapshot carries a payload the current version wrote, which
    # loads faster than a small tree parses; a snapshot with only the YAML
    # graph, which loads slower than that, is reused only under the cache
    # directive, and without a snapshot, or with one taken under other
    # settings, every file is read.
    def analyze_for_check(definition, root, paths, options)
      scoped = paths.any? && !options[:update_todo] && !options[:baseline]
      reused = reusable_snapshot(definition, root) if scoped
      return Analyzer.analyze(definition, root: root) unless reused

      Analyzer.analyze_scoped(definition, root: root, reused: reused.graph, paths: paths)
    end

    def reusable_snapshot(definition, root)
      directory = File.expand_path(Snapshot::DEFAULT_DIRECTORY, root)
      return unless File.exist?(File.join(directory, Snapshot::RECEIPT_FILE))

      snapshot = definition.cache_path ? Snapshot.load(directory, root: root) : Snapshot.load_payload(directory, root: root)
      return unless snapshot

      receipt = snapshot.receipt
      patterns = (definition.analysis_patterns + definition.ignore_patterns).sort
      return unless receipt.archspec_version == ArchSpec::VERSION && receipt.root == root && receipt.patterns == patterns

      snapshot
    rescue Error
      nil
    end

    # Compares receipts before anything else: two snapshots that were not
    # produced the same way decline with their own exit status, so a run that
    # could not compare never reads as a run that passed.
    def check_against_baseline(options, paths, output, formatter, definition, root, graph, todo, diagnostics, mode)
      baseline = Snapshot.load(options[:baseline], root: root) do |cause|
        output.puts "snapshot: #{cause}; reading the YAML graph instead, which is slower"
      end
      current = Snapshot.receipt_for(graph, definition, definition_digest: definition_digest(options[:config]),
                                                        commit: GitTree.commit(root), dirty: GitTree.dirty?(root))
      if (cause = current.incomparable_with(baseline.receipt))
        output.puts "archspec: declined: #{cause}; take a new snapshot and check again."
        return DECLINED_STATUS
      end

      baseline_diagnostics = Evaluator.evaluate(definition, baseline.graph, todo: todo,
                                                                            housekeeping: options[:housekeeping])
      delta = Delta.between(baseline, graph, diagnostics, baseline_diagnostics, root: root,
                                                                                changed_files: baseline.changed_files(graph))
      delta = delta.scoped { |bucket| scope_to_paths(bucket, paths, root) }

      formatter.print_delta(output, graph: graph, diagnostics: scope_to_paths(diagnostics, paths, root), delta: delta,
                                    mode: mode)
      delta.failed?(mode) ? 1 : 0
    end

    def snapshot(argv, output)
      options = { config: CONFIG_FILE, output: Snapshot::DEFAULT_DIRECTORY, help: false }
      parser = OptionParser.new do |opts|
        opts.banner = usage('snapshot').strip
        opts.on('--config PATH', 'Use a different architecture file') { |value| options[:config] = value }
        opts.on('--output DIR', 'Write the snapshot here instead of .archspec') { |value| options[:output] = value }
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
      end
      parser.parse!(argv)

      if options[:help]
        output.puts parser
        return 0
      end

      raise UsageError, "unexpected argument: #{argv.first}" if argv.any?

      definition, root = load_definition(options[:config])
      graph = Analyzer.analyze(definition, root: root)
      snapshot = Snapshot.write(options[:output], graph: graph, definition: definition,
                                                  definition_digest: definition_digest(options[:config]),
                                                  commit: GitTree.commit(root), dirty: GitTree.dirty?(root))

      directory = Pathname(File.expand_path(options[:output], root)).relative_path_from(Pathname(root))
      at = snapshot.receipt.commit ? " at #{snapshot.receipt.commit[0, 12]}#{' (dirty)' if snapshot.receipt.dirty}" : ''
      output.puts "Wrote #{directory}/ (#{graph.files.size} files, #{graph.constants.size} constants, " \
                  "#{graph.edges.size} facts)#{at}."
      0
    end

    def definition_digest(config_path)
      Digest::SHA256.file(File.expand_path(config_path)).hexdigest
    end

    def explain(argv, output)
      options = { config: CONFIG_FILE, help: false }
      parser = OptionParser.new do |opts|
        opts.banner = usage('explain').strip
        opts.on('--config PATH', 'Use a different architecture file') { |value| options[:config] = value }
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
      end
      parser.parse!(argv)

      if options[:help]
        output.puts parser
        return 0
      end

      subject = argv.shift
      raise UsageError, 'missing PATH_OR_CONSTANT' unless subject
      raise UsageError, "unexpected argument: #{argv.first}" if argv.any?

      definition, root = load_definition(options[:config])
      graph = Analyzer.analyze(definition, root: root)
      Formatters::Explanation.print(output, graph: graph, subject: subject)
      0
    end

    # Runs the Active Record reflector inside the application through
    # <tt>bin/rails runner</tt>, the only ArchSpec command that boots the app.
    # The facts file it writes is what +check+ merges on later static runs.
    def reflect(argv, output)
      options = { config: CONFIG_FILE, output: nil, static: false, help: false }
      parser = OptionParser.new do |opts|
        opts.banner = usage('reflect').strip
        opts.on('--config PATH', 'Use a different architecture file') { |value| options[:config] = value }
        opts.on('--output PATH', 'Write the facts file here instead of the facts directory') do |value|
          options[:output] = value
        end
        opts.on('--static', 'Resolve associations from the source alone, without booting') do
          options[:static] = true
        end
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
      end
      parser.parse!(argv)

      if options[:help]
        output.puts parser
        return 0
      end

      raise UsageError, "unexpected argument: #{argv.first}" if argv.any?

      definition, root = load_definition(options[:config])
      return reflect_static(definition, root, options[:output], output) if options[:static]

      runner = File.join(root, 'bin', 'rails')
      raise Error, "no bin/rails at #{root}; reflect runs inside a Rails application" unless File.executable?(runner)

      destination = File.expand_path(options[:output] || File.join(definition.facts_path, 'rails.yml'), root)
      lib = File.expand_path('..', __dir__)
      script = "$LOAD_PATH.unshift(#{lib.inspect}) unless $LOAD_PATH.include?(#{lib.inspect}); " \
               "require 'archspec'; ArchSpec::Reflect.run(output: #{destination.inspect}, root: #{root.inspect})"
      _stdout, stderr, status = Open3.capture3(runner, 'runner', script, chdir: root)
      unless status.success?
        detail = stderr.lines.last(5).join.strip
        raise Error, "bin/rails runner failed; the facts file was not written#{detail.empty? ? '' : ": #{detail}"}"
      end

      output.puts "Wrote #{Pathname(destination).relative_path_from(Pathname(root))}"
      output.puts summary_line(Facts.load_file(destination, root: root)) if File.exist?(destination)
      0
    end

    def reflect_static(definition, root, destination, output)
      destination = File.expand_path(destination || File.join(definition.facts_path, 'associations.yml'), root)
      graph = Analyzer.analyze(definition, root: root)
      facts = Associations.write(graph, output: destination, root: root)
      output.puts "Wrote #{Pathname(destination).relative_path_from(Pathname(root))}"
      output.puts summary_line(facts)
      0
    end

    def summary_line(facts)
      facts = { references: facts.references, misses: facts.misses } unless facts.is_a?(Hash)
      misses = facts[:misses].map { |cause, count| "#{cause} #{count}" }.join(', ')
      references = facts[:references].size
      label = references == 1 ? 'reference' : 'references'
      misses.empty? ? "#{references} #{label}, no misses" : "#{references} #{label}; misses: #{misses}"
    end

    def load_definition(config_path)
      raise Error, "no #{config_path} found; run `archspec init` first" unless File.exist?(config_path)

      absolute_config = File.expand_path(config_path)
      definition = Definition.new
      definition.base_dir = File.dirname(absolute_config)
      definition.extend(DSL::Context)
      definition.instance_eval(File.read(absolute_config), absolute_config)

      if definition.component_specs.empty? && definition.rules.empty?
        raise Error, "#{config_path} declared no components or rules; the file's top level is already " \
                     'the DSL, so do not wrap declarations in ArchSpec.define'
      end

      [definition, definition.absolute_root]
    rescue Error
      raise
    rescue SyntaxError, LoadError, StandardError => e
      detail = e.message.lines.first&.strip || e.class.name
      raise Error, "could not load #{config_path}: #{detail}"
    end

    def scope_to_paths(diagnostics, paths, root)
      return diagnostics if paths.empty?

      expanded = paths.map { |path| File.expand_path(path, root) }
      diagnostics.select do |diagnostic|
        expanded.any? do |path|
          diagnostic.location.path == path || diagnostic.location.path.start_with?("#{path}/")
        end
      end
    end

    def todo_path_for(definition, root)
      return unless definition.todo_path

      File.expand_path(definition.todo_path, root)
    end

    def formatter_for(name)
      case name
      when 'text'
        Formatters::Text
      when 'json'
        Formatters::JSON
      else
        raise UsageError, "unknown format: #{name.inspect}"
      end
    end

    def usage(command = nil)
      case command.to_s
      when 'init'
        'Usage: archspec init [PATH] [--force]'
      when 'check'
        'Usage: archspec check [PATHS...] [--config PATH] [--format text|json] [--update-todo] ' \
          '[--housekeeping] [--baseline [DIR]] [--mode ratchet|advisory|strict]'
      when 'snapshot'
        'Usage: archspec snapshot [--config PATH] [--output DIR]'
      when 'explain'
        'Usage: archspec explain PATH_OR_CONSTANT [--config PATH]'
      when 'reflect'
        'Usage: archspec reflect [--config PATH] [--output PATH] [--static]'
      when 'version'
        'Usage: archspec version'
      when ''
        <<~TEXT
          Usage:
            archspec init [PATH] [--force]
            archspec check [PATHS...] [--config PATH] [--format text|json] [--update-todo] [--housekeeping]
            archspec check [PATHS...] --baseline [DIR] [--mode ratchet|advisory|strict]
            archspec snapshot [--config PATH] [--output DIR]
            archspec explain PATH_OR_CONSTANT [--config PATH]
            archspec reflect [--config PATH] [--output PATH] [--static]
            archspec version
            archspec help [COMMAND]
        TEXT
      else
        usage
      end
    end
  end
end
