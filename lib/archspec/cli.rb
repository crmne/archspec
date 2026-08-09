# frozen_string_literal: true

require 'optparse'

module ArchSpec
  # The <tt>archspec</tt> command line. Backs the +exe/archspec+ executable and
  # dispatches the +init+, +check+, +explain+, and +version+ subcommands.
  #
  #   archspec init
  #   archspec check [PATHS...] [--config PATH] [--format text|json] [--update-todo]
  #   archspec explain PATH_OR_CONSTANT
  #
  # #run returns the process exit status: 0 when clean, 1 when violations are
  # found.
  module CLI
    extend self

    CONFIG_FILE = 'Archspec.rb'
    TEMPLATE = <<~RUBY
      architecture :rails
    RUBY

    def run(argv, output: $stdout, error: $stderr)
      argv = argv.dup
      command = argv.shift || 'check'

      case command
      when 'init'
        init(argv, output)
      when 'check'
        check(argv, output)
      when 'explain'
        explain(argv, output)
      when 'version', '--version', '-v'
        output.puts ArchSpec::VERSION
        0
      else
        error.puts "Unknown command: #{command}"
        error.puts usage
        64
      end
    rescue Error => e
      error.puts e.message
      1
    end

    private

    def init(argv, output)
      force = argv.delete('--force')
      path = argv.shift || CONFIG_FILE

      raise Error, "#{path} already exists. Use --force to overwrite it." if File.exist?(path) && !force

      File.write(path, TEMPLATE)
      output.puts "Created #{path}"
      0
    end

    def check(argv, output)
      options = {
        config: CONFIG_FILE,
        format: 'text',
        update_todo: false
      }

      parser = OptionParser.new do |opts|
        opts.on('--config PATH') { |value| options[:config] = value }
        opts.on('--format FORMAT') { |value| options[:format] = value }
        opts.on('--update-todo') { options[:update_todo] = true }
      end
      parser.parse!(argv)

      raise Error, 'Cannot combine --update-todo with path arguments.' if options[:update_todo] && argv.any?

      definition, root = load_definition(options[:config])
      graph = Analyzer.analyze(definition, root: root)
      todo_path = todo_path_for(definition, root)
      todo = options[:update_todo] ? Todo.empty(root: root) : Todo.load(todo_path, root: root)
      diagnostics = Evaluator.evaluate(definition, graph, todo: todo)
      diagnostics = scope_to_paths(diagnostics, argv, root)

      if options[:update_todo]
        unless todo_path
          raise Error,
                "No todo configured. Add `todo \"archspec_todo.yml\"` to #{options[:config]}."
        end

        Todo.write(todo_path, diagnostics, root: root)
        output.puts "Updated #{Pathname(todo_path).relative_path_from(Pathname(root))} with #{diagnostics.size} violations."
        return 0
      end

      formatter_for(options[:format]).print(output, graph: graph, diagnostics: diagnostics)
      diagnostics.empty? ? 0 : 1
    end

    def explain(argv, output)
      options = { config: CONFIG_FILE }
      parser = OptionParser.new do |opts|
        opts.on('--config PATH') { |value| options[:config] = value }
      end
      parser.parse!(argv)

      subject = argv.shift
      raise Error, 'Usage: archspec explain PATH_OR_CONSTANT' unless subject

      definition, root = load_definition(options[:config])
      graph = Analyzer.analyze(definition, root: root)
      Formatters::Explanation.print(output, graph: graph, subject: subject)
      0
    end

    def load_definition(config_path)
      raise Error, "Missing #{config_path}. Run `archspec init` first." unless File.exist?(config_path)

      ArchSpec.last_definition = nil
      absolute_config = File.expand_path(config_path)
      config_dir = File.dirname(absolute_config)
      definition = Definition.new
      definition.base_dir = config_dir
      definition.extend(DSL::Context)
      definition.instance_eval(File.read(absolute_config), absolute_config)
      definition = ArchSpec.last_definition || definition
      definition.base_dir ||= config_dir

      [definition, definition.absolute_root(config_dir)]
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
        raise Error, "Unknown format: #{name.inspect}"
      end
    end

    def usage
      <<~TEXT
        Usage:
          archspec init [PATH] [--force]
          archspec check [PATHS...] [--config PATH] [--format text|json] [--update-todo]
          archspec explain PATH_OR_CONSTANT [--config PATH]
          archspec version
      TEXT
    end
  end
end
