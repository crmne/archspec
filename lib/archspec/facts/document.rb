# frozen_string_literal: true

module ArchSpec
  module Facts
    # Decodes a complete batch before any graph mutation. Both the in-memory
    # builder and external YAML documents must satisfy this contract.
    class Document
      LOCATION_KEYS = %w[path line column end_line end_column].freeze
      ENTRY_LOCATION_KEYS = LOCATION_KEYS + %w[source_path]
      LEGACY_LIST_KEYS = %w[references methods gaps].freeze
      METHOD_KEYS = %w[visibility signatures alias_target mode installation].freeze
      SCOPES = %w[instance class].freeze

      def initialize(graph, document, label)
        @graph = graph
        @document = document
        @label = label
        @lines = {}
      end

      def validate_snapshot(current)
        validate_envelope
        unless @document['snapshot'] == current
          raise Error, "stale facts file #{@label}: source or configuration changed; regenerate it with its producer"
        end
        environment = @document['environment']
        if environment && ENV['RAILS_ENV'] && ENV['RAILS_ENV'] != environment
          raise Error, "facts file #{@label} was captured for #{environment}, but RAILS_ENV is #{ENV['RAILS_ENV']}"
        end
      end

      def compile
        validate_envelope
        Operations.new(**LIST_KEYS.to_h do |key|
          [key.to_sym, Array(@document[key]).flat_map { |entry| public_send("decode_#{key}", entry) }]
        end)
      end

      def decode_references(entry)
        validate_entry(entry, %w[source target])
        Reference.new(source_for(entry, 'source'), constant_name(entry['target']), location_for(entry))
      end

      def decode_methods(entry)
        validate_entry(entry, %w[owner scope names] + (@document['version'] == 1 ? [] : METHOD_KEYS))
        owner = source_for(entry, 'owner')
        location = location_for(entry)
        scope = enum(entry['scope'], SCOPES, 'method scope')
        names = string_list(entry['names'], 'method names', nonempty: true)
        visibility = enum(entry.fetch('visibility', 'public'), %w[public protected private], 'method visibility')
        mode = enum(entry.fetch('mode', 'if_missing'), %w[if_missing append define], 'method mode')
        installation = entry['installation']
        if mode == :define
          invalid('define mode requires an installation location') unless installation.is_a?(Hash)
          invalid('invalid installation fields') unless (installation.keys - LOCATION_KEYS).empty?
          installation = location_for(installation)
        elsif !installation.nil?
          invalid('installation requires define mode')
        end
        signatures = entry.fetch('signatures', [])
        invalid('expected a list of signatures') unless signatures.is_a?(Array)
        signatures = signatures.map { |signature| signature_for(signature) }
        alias_target = entry['alias_target']
        string(alias_target, 'alias target') unless alias_target.nil?
        names.map do |name|
          definition = MethodDefinition.new(owner.name, name.to_sym, scope, location, visibility, signatures, alias_target&.to_sym)
          Method.new(owner, definition, mode, installation)
        end
      end

      def decode_mixins(entry)
        validate_entry(entry, %w[owner target kind])
        Mixin.new(source_for(entry, 'owner'), constant_name(entry['target']),
          enum(entry['kind'], %w[include prepend extend singleton_prepend], 'mixin kind'), location_for(entry))
      end

      def decode_receivers(entry)
        validate_entry(entry, %w[source name receiver scope])
        source = source_for(entry, 'source')
        name = string(entry['name'], 'call name')
        location = location_for(entry)
        unless @graph.edges.any? do |edge|
          edge.type == :calls_named_method && edge.receiver == :none && edge.from_constant == source.name &&
            edge.from_path == source.path && edge.to == name && edge.location == location
        end
          invalid('receiver binding must identify an existing receiverless call with its complete source range')
        end
        Receiver.new(source, name, location, constant_name(entry['receiver']), enum(entry['scope'], SCOPES, 'receiver scope'))
      end

      def decode_exposures(entry)
        validate_entry(entry, %w[source owner scope])
        source = source_for(entry, 'source')
        location_for(entry)
        invalid('method exposure source must be a module') unless source.module?
        owner = constant_name(entry['owner'])
        invalid("method exposure owner #{owner} is not analyzed") if @graph.constants_named(owner).empty?
        Exposure.new(source, owner, enum(entry['scope'], SCOPES, 'exposure scope'))
      end

      def decode_gaps(entry)
        validate_entry(entry, %w[source message])
        Gap.new(source_for(entry, 'source'), string(entry['message'], 'gap message'), location_for(entry))
      end

      private

      def validate_envelope
        unless @document.is_a?(Hash) && @document['version'].is_a?(Integer) && [1, VERSION].include?(@document['version'])
          invalid("expected version 1 or #{VERSION}")
        end
        lists = @document['version'] == 1 ? LEGACY_LIST_KEYS : LIST_KEYS
        keys = %w[version producer environment snapshot] + lists
        invalid('unknown document fields') unless (@document.keys - keys).empty?
        string(@document['producer'], 'producer')
        unless @document['environment'].nil? || @document['environment'].is_a?(String)
          invalid('expected an environment string')
        end
        invalid('expected fact lists') unless lists.all? { |key| @document[key].nil? || @document[key].is_a?(Array) }
      end

      def signature_for(value)
        unless value.is_a?(Hash) && (value.keys - MethodSignature.members.map(&:to_s)).empty?
          invalid('invalid method signature fields')
        end
        counts = %w[required optional].to_h do |key|
          number = value.fetch(key, 0)
          invalid("invalid signature #{key}") unless number.is_a?(Integer) && number >= 0
          [key.to_sym, number]
        end
        flags = %w[rest keyword_rest block forward].to_h do |key|
          flag = value.fetch(key, false)
          invalid("invalid signature #{key}") unless flag == true || flag == false
          [key.to_sym, flag]
        end
        keywords = %w[keywords optional_keywords].to_h do |key|
          [key.to_sym, string_list(value.fetch(key, []), "signature #{key}").map(&:to_sym)]
        end
        invalid('required and optional keywords overlap') unless (keywords[:keywords] & keywords[:optional_keywords]).empty?
        MethodSignature.new(**counts, **flags, **keywords)
      end

      def validate_entry(entry, keys)
        invalid('invalid entry fields') unless entry.is_a?(Hash) && (entry.keys - keys - ENTRY_LOCATION_KEYS).empty?
      end

      def enum(value, values, label)
        invalid("invalid #{label}: expected #{values.join(', ')}") unless values.include?(value)
        value.to_sym
      end

      def string(value, label)
        invalid("expected a nonempty #{label}") unless value.is_a?(String) && !value.empty?
        value
      end

      def string_list(value, label, nonempty: false)
        unless value.is_a?(Array) && (!nonempty || !value.empty?) && value.all? { |item| item.is_a?(String) && !item.empty? }
          invalid("invalid #{label}")
        end
        value
      end

      def source_for(entry, key)
        name = constant_name(entry[key])
        source_path = project_path(entry['source_path'] || entry['path'])
        source = @graph.constants_named(name).find { |node| node.path == source_path }
        invalid("#{name} is not defined in #{entry['source_path'] || entry['path']}") unless source
        source
      end

      def constant_name(value)
        unless value.is_a?(String) && /\A(?:::)?[[:upper:]][[:alnum:]_]*(?:::[[:upper:]][[:alnum:]_]*)*\z/.match?(value)
          invalid('invalid constant name')
        end
        value.delete_prefix('::')
      end

      def project_path(value)
        invalid('invalid source path') unless value.is_a?(String) && !Pathname(value).absolute?
        expanded = File.expand_path(value, @graph.root)
        unless expanded.start_with?("#{@graph.root}/") && @graph.files.key?(expanded)
          invalid("source path #{value} is not analyzed")
        end
        expanded
      end

      def location_for(entry)
        source = project_path(entry['path'])
        line = entry['line']
        column = entry.fetch('column', 1)
        end_line = entry.fetch('end_line', line)
        end_column = entry.fetch('end_column', column)
        lines = @lines[source] ||= File.readlines(source)
        valid = [line, column, end_line, end_column].all? { |value| value.is_a?(Integer) && value.positive? }
        valid &&= line <= lines.size && end_line <= lines.size &&
                  ([line, column] <=> [end_line, end_column]) <= 0 &&
                  column <= lines[line - 1].chomp.bytesize + 1 && end_column <= lines[end_line - 1].chomp.bytesize + 1
        invalid('invalid source location') unless valid
        SourceLocation.new(source, line, column, end_line, end_column)
      end

      def invalid(message)
        raise Error, "invalid facts file #{@label}: #{message}"
      end
    end
  end
end
