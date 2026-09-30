# frozen_string_literal: true

module ArchSpec
  # A named source of runtime facts. <tt>archspec reflect</tt> runs each
  # producer declared in +Archspec.rb+ in its own process: it boots the
  # framework, analyzes the source, lets the producer record what it observes
  # through a Facts::Builder, and writes <tt><facts>/<name>.yml</tt>.
  #
  #   ArchSpec.producer :widgets do
  #     inputs "config/widgets.yml"          # global: a change invalidates every fact
  #     sources "app/widgets/**/*.rb"        # per file: a change invalidates that file's facts
  #     env "WIDGETS_ENV"                    # must match when a check sets it
  #
  #     boot { |root| require File.join(root, "config/environment") }
  #
  #     capture do |facts|
  #       Widgets.registry.each do |widget, service|
  #         facts.reference(source: widget, target: service, location: widget.declaration_site)
  #       end
  #     end
  #   end
  #
  # Checks never run producers; they read the files they wrote.
  class Producer
    attr_reader :name, :input_patterns, :source_patterns, :env_names

    class << self
      def registry
        @registry ||= {}
      end

      def register(name, &block)
        registry[name.to_s] = new(name, &block)
      end

      # Requires the file a declaration names, then returns the registered
      # producer. Paths starting with a dot resolve against +Archspec.rb+.
      def load(name, definition)
        path = definition.producers.fetch(name.to_s) do
          raise Error, "producer #{name} is not declared; add `reflect :#{name}` to Archspec.rb"
        end
        if path
          require(path.start_with?('.') ? File.expand_path(path, definition.base_dir || Dir.pwd) : path)
        end
        registry.fetch(name.to_s) do
          raise Error, "no producer named #{name} is registered#{" by #{path}" if path}"
        end
      rescue LoadError => error
        raise Error, "could not load producer #{name}: #{error.message}"
      end
    end

    def initialize(name, &block)
      @name = name.to_s
      @input_patterns = Facts::DEFAULT_INPUTS.dup
      @source_patterns = []
      @env_names = []
      block.arity == 1 ? yield(self) : instance_eval(&block) if block
      raise Error, "producer #{@name} has no capture block" unless @capture
    end

    # Files outside the analyzed source whose change invalidates the whole
    # document. The defaults cover +config/+, the Gemfile and lockfile,
    # gemspecs, and the Ruby version.
    def inputs(*patterns)
      @input_patterns |= patterns.flatten.map(&:to_s)
    end

    # Analyzed files this producer inspects. A changed, added, or removed file
    # invalidates only the facts it contributed. Files the facts cite are
    # always covered.
    def sources(*patterns)
      @source_patterns |= patterns.flatten.map(&:to_s)
    end

    # Environment variables whose values shape what the producer observes.
    # They are recorded as captured, so do not name secrets.
    def env(*names)
      @env_names |= names.flatten.map(&:to_s)
    end

    def boot(&block)
      @boot = block
    end

    def capture(&block)
      @capture = block
    end

    # Boots, analyzes, and captures; returns the validated document.
    def run(definition, root)
      begin
        instance_exec(root, &@boot) if @boot
      rescue Error
        raise
      rescue StandardError, ScriptError => error
        raise Error, "could not boot: #{error.message.strip} (#{error.class})#{origin(error, root)}"
      end
      graph = Analyzer.analyze(definition, root: root, include_facts: false)
      raise Error, 'cannot reflect source with syntax errors' if graph.files.values.any? { |file| file.parse_errors.any? }

      facts = Facts::Builder.new(graph, producer: name)
      begin
        instance_exec(facts, &@capture)
      rescue Error
        raise
      rescue StandardError, ScriptError => error
        raise Error, "capture failed: #{error.message.strip} (#{error.class})#{origin(error, root)}"
      end
      facts.to_document(facts_path: definition.facts_path, inputs: input_patterns, sources: source_patterns,
        env: env_names.filter_map { |variable| [variable, ENV[variable]] if ENV[variable] }.to_h)
    end

    private

    # The first backtrace frame in the project, which is usually where the
    # fix belongs.
    def origin(error, root)
      frames = Array(error.backtrace)
      frame = frames.find { |line| line.start_with?("#{root}/") && !line.include?('/vendor/') } || frames.first
      frame ? "\n  at #{frame.delete_prefix("#{root}/")}" : ''
    end
  end

  # Registers a facts producer. See ArchSpec::Producer.
  def self.producer(name, &block)
    Producer.register(name, &block)
  end
end
