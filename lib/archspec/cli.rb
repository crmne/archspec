# frozen_string_literal: true

require 'open3'
require 'optparse'
require 'rbconfig'

module ArchSpec
  # The <tt>archspec</tt> command line. Backs the +exe/archspec+ executable and
  # dispatches the +init+, +check+, +explain+, +reflect+, and +version+ subcommands.
  #
  #   archspec init
  #   archspec check [PATHS...] [--config PATH] [--format text|json] [--update-todo|--check-todo]
  #   archspec explain PATH_OR_CONSTANT
  #
  # #run returns the process exit status: 0 when clean, 1 when violations are
  # found (or, with <tt>--check-todo</tt>, when the todo lists violations that
  # no longer occur).
  module CLI
    extend self

    CONFIG_FILE = 'Archspec.rb'
    USAGE_ERROR_STATUS = 64
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
      if subject && !%w[init check explain reflect version].include?(subject)
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
        check_todo: false,
        help: false
      }

      parser = OptionParser.new do |opts|
        opts.banner = usage('check').strip
        opts.on('--config PATH', 'Use a different architecture file') { |value| options[:config] = value }
        opts.on('--format FORMAT', 'Output text or json') { |value| options[:format] = value }
        opts.on('--update-todo', 'Replace the configured todo with current violations') do
          options[:update_todo] = true
        end
        opts.on('--check-todo', 'Also fail when the configured todo lists violations that no longer occur') do
          options[:check_todo] = true
        end
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
      end
      parser.parse!(argv)

      if options[:help]
        output.puts parser
        return 0
      end

      raise Error, 'cannot combine --update-todo with path arguments' if options[:update_todo] && argv.any?
      raise Error, 'cannot combine --update-todo with --check-todo' if options[:update_todo] && options[:check_todo]

      formatter = formatter_for(options[:format])
      definition, root = load_definition(options[:config])
      todo_path = todo_path_for(definition, root)
      if (options[:update_todo] || options[:check_todo]) && !todo_path
        raise Error, "no todo configured; add `todo \"archspec_todo.yml\"` to #{options[:config]}"
      end

      if options[:check_todo] && !File.exist?(todo_path)
        raise Error, "todo file #{Pathname(todo_path).relative_path_from(Pathname(root))} does not exist; " \
                     'run `archspec check --update-todo` to create it'
      end

      graph = Analyzer.analyze(definition, root: root)
      candidates = Evaluator.unsuppressed(definition, graph)
      # Syntax errors and stale facts are never an accepted baseline; they must be fixed.
      acceptable = candidates.reject { |diagnostic| ['parser.syntax', Facts::STALE_RULE].include?(diagnostic.rule) }

      if options[:update_todo]
        if candidates.any? { |diagnostic| diagnostic.rule == Facts::STALE_RULE }
          raise Error, 'facts are out of date; run `archspec reflect` before updating the todo'
        end

        count = Todo.write(todo_path, acceptable, root: root)
        label = count == 1 ? 'entry' : 'entries'
        output.puts "Updated #{Pathname(todo_path).relative_path_from(Pathname(root))} with #{count} #{label}."
        return 0
      end

      todo = Todo.load(todo_path, root: root)
      diagnostics = candidates.reject { |diagnostic| todo.include?(diagnostic) }
      diagnostics = scope_to_paths(diagnostics, argv, root, graph)
      obsolete = scope_entries_to_paths(todo.unmatched_by(acceptable), argv, root) if options[:check_todo]

      formatter.print(output, graph: graph, diagnostics: diagnostics, obsolete_todo: obsolete)
      diagnostics.empty? && (obsolete.nil? || obsolete.empty?) ? 0 : 1
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

    public

    # Evaluates an +Archspec.rb+ file and returns the definition and its root.
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

    private

    def reflect(argv, output)
      options = { config: CONFIG_FILE, environment: nil, help: false }
      parser = OptionParser.new do |opts|
        opts.banner = usage('reflect')
        opts.on('--config PATH', 'Use a different architecture file') { |value| options[:config] = value }
        opts.on('--environment NAME', 'Set RAILS_ENV for the producers (default: RAILS_ENV or development)') do |value|
          options[:environment] = value
        end
        opts.on('-h', '--help', 'Show this help') { options[:help] = true }
      end
      parser.parse!(argv)
      if options[:help]
        output.puts parser
        return 0
      end

      definition, root = load_definition(options[:config])
      unless definition.facts_path
        raise Error, "no facts configured; add `reflect :rails` or `facts \"archspec_facts\"` to #{options[:config]}"
      end
      names = argv.empty? ? definition.producers.keys : argv
      undeclared = names - definition.producers.keys
      raise UsageError, "undeclared producer: #{undeclared.first}" if undeclared.any?

      environment = { 'ARCHSPEC_REFLECTION_CONFIG' => File.expand_path(options[:config]) }
      environment['RAILS_ENV'] = options[:environment] if options[:environment]
      runner = File.expand_path('reflect_runner.rb', __dir__)
      results = names.map do |name|
        Thread.new do
          Open3.capture3(environment.merge('ARCHSPEC_PRODUCER' => name), RbConfig.ruby, runner, chdir: root)
        rescue SystemCallError => e
          ['', e.message, nil]
        end
      end.map(&:value)

      failures = names.zip(results).reject do |_, (stdout, _, status)|
        output.print stdout
        status&.success?
      end
      return 0 if failures.empty?

      raise Error, failures.map { |name, (_, stderr, status)|
        "#{name} producer failed#{" (exit #{status.exitstatus})" if status&.exitstatus}: #{stderr.strip}"
      }.join("\n")
    end

    # A stale facts document affects every path, so it is always reported.
    def scope_to_paths(diagnostics, paths, root, graph)
      return diagnostics if paths.empty?

      expanded = paths.map { |path| File.expand_path(path, root) }
      diagnostics.select do |diagnostic|
        within?(diagnostic.location.path, expanded) ||
          (diagnostic.rule == Facts::STALE_RULE && !graph.files.key?(diagnostic.location.path))
      end
    end

    def scope_entries_to_paths(entries, paths, root)
      return entries if paths.empty?

      expanded = paths.map { |path| File.expand_path(path, root) }
      entries.select { |entry| entry['path'] && within?(File.expand_path(entry['path'], root), expanded) }
    end

    def within?(path, scopes)
      scopes.any? { |scope| path == scope || path.start_with?("#{scope}/") }
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
        'Usage: archspec check [PATHS...] [--config PATH] [--format text|json] [--update-todo|--check-todo]'
      when 'explain'
        'Usage: archspec explain PATH_OR_CONSTANT [--config PATH]'
      when 'reflect'
        'Usage: archspec reflect [PRODUCERS...] [--config PATH] [--environment NAME]'
      when 'version'
        'Usage: archspec version'
      when ''
        <<~TEXT
          Usage:
            archspec init [PATH] [--force]
            archspec check [PATHS...] [--config PATH] [--format text|json] [--update-todo|--check-todo]
            archspec explain PATH_OR_CONSTANT [--config PATH]
            archspec reflect [PRODUCERS...] [--config PATH] [--environment NAME]
            archspec version
            archspec help [COMMAND]
        TEXT
      else
        usage
      end
    end
  end
end
