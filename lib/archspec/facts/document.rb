# frozen_string_literal: true

module ArchSpec
  module Facts
    # Decodes a complete batch before any graph mutation. Both the in-memory
    # builder and external YAML documents must satisfy this contract.
    class Document
      LOCATION_KEYS = %w[path line column end_line end_column].freeze
      ENTRY_LOCATION_KEYS = LOCATION_KEYS + %w[source_path depends_on]
      LEGACY_LIST_KEYS = %w[references methods gaps].freeze
      LEGACY_ENVELOPE_KEYS = %w[version producer environment snapshot].freeze
      ENVELOPE_KEYS = %w[version producer env inputs sources snapshot].freeze
      METHOD_KEYS = %w[visibility signatures alias_target mode installation].freeze
      SCOPES = %w[instance class].freeze

      def initialize(graph, document, label)
        @graph = graph
        @document = document
        @label = label
        @lines = {}
        @stale = Set.new
        @removed = Set.new
      end

      # Compiles an imported document, or returns nil when it no longer
      # describes the source. Stale files are reported and their facts skipped.
      def compile_fresh(excluding:)
        validate_envelope
        reason = @document['version'] == 1 ? legacy_staleness(excluding) : staleness(excluding)
        if reason
          stale_diagnostic(@label, "#{producer} facts are out of date: #{reason}; run `archspec reflect`")
          return
        end

        @stale.each do |path|
          stale_diagnostic(path, "#{producer} facts are out of date for this file; run `archspec reflect`")
        end
        compile
      end

      def compile
        validate_envelope
        Operations.new(*LIST_KEYS.map do |key|
          Array(@document[key]).reject { |entry| stale_entry?(entry) }
                               .flat_map do |entry|
                                 validate_dependencies(entry)
                                 public_send("decode_#{key}", entry)
                               end
        end, producer)
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
        unless receiverless_calls.include?([source.name, source.path, name, location])
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

      def decode_resolves(entry)
        validate_entry(entry, %w[source message consumers])
        source = source_for(entry, 'source')
        return [] if new_consumers?(source, entry['consumers'])

        location = location_for(entry)
        message = entry['message'].nil? ? nil : string(entry['message'], 'gap message')
        unless @graph.edges.any? do |edge|
          edge.type == :dynamic_feature && edge.from_constant == source.name && edge.from_path == source.path &&
            edge.location == location && (message.nil? || edge.to == message)
        end
          invalid('a resolution must identify an existing analysis gap with its complete source range')
        end
        Resolve.new(source, message, location)
      end

      private

      def producer
        @document['producer']
      end

      def legacy_staleness(excluding)
        return 'source or configuration changed' unless @document['snapshot'] == Facts.snapshot(@graph, excluding: excluding)

        environment = @document['environment']
        return unless environment && ENV['RAILS_ENV'] && ENV['RAILS_ENV'] != environment

        "captured for RAILS_ENV=#{environment}, but RAILS_ENV is #{ENV['RAILS_ENV']}"
      end

      # Changes to global inputs, or to the recorded environment, invalidate
      # the document. A changed, added, or removed analyzed file only
      # invalidates the facts that cite it.
      def staleness(excluding)
        (@document['env'] || {}).each do |name, value|
          current = ENV.fetch(name, nil)
          return "captured with #{name}=#{value}, but it is #{current}" if current && current != value
        end

        recorded = @document['snapshot'] || {}
        inputs = Facts.input_files(@graph, @document['inputs'] || [], excluding: excluding)
        sources = Facts.source_files(@graph, @document['sources'] || [])
        candidates = recorded.keys.map { |path| File.expand_path(path, @graph.root) } | inputs | sources
        root = Pathname(@graph.root)
        candidates.sort.each do |path|
          relative = Pathname(path).relative_path_from(root).to_s
          next if recorded[relative] == Facts.digest(path)
          return "#{relative} changed" if inputs.include?(path) || input_pattern?(relative)

          # A covered file that is gone takes its facts with it; one that
          # changed reports them as stale.
          (@graph.files.key?(path) ? @stale : @removed) << path
        end
        nil
      end

      def stale_diagnostic(path, message)
        @graph.fact_diagnostics << Diagnostic.new(rule: STALE_RULE, message: message,
          location: SourceLocation.point(File.expand_path(path), 1, 1),
          evidence: Pathname(File.expand_path(@label)).relative_path_from(Pathname(@graph.root)).to_s)
      end

      def stale_entry?(entry)
        return false if (@stale.empty? && @removed.empty?) || !entry.is_a?(Hash)

        installation = entry['installation'].is_a?(Hash) ? entry['installation']['path'] : nil
        dependencies = entry['depends_on'].is_a?(Array) ? entry['depends_on'] : []
        [entry['path'], entry['source_path'], installation, *dependencies].any? do |path|
          next false unless path.is_a?(String)

          expanded = File.expand_path(path, @graph.root)
          @stale.include?(expanded) || @removed.include?(expanded)
        end
      end

      def input_pattern?(relative)
        (@document['inputs'] || []).any? do |pattern|
          File.fnmatch?(pattern, relative, File::FNM_PATHNAME | File::FNM_EXTGLOB | File::FNM_DOTMATCH)
        end
      end

      # Files an entry depends on beyond its own location, such as the owner
      # of an exposure. They must be fingerprinted so an edit is noticed.
      def validate_dependencies(entry)
        return unless entry.is_a?(Hash) && entry.key?('depends_on')

        paths = string_list(entry['depends_on'], 'dependencies')
        snapshot = @document['snapshot']
        missing = snapshot && paths.find { |path| !snapshot.key?(path) }
        invalid("the snapshot does not fingerprint #{missing}") if missing
      end

      # A resolution holds only for the consumers the producer inspected. A
      # consumer added since then was never observed, so it is reported.
      def new_consumers?(source, recorded)
        return false if recorded.nil?

        string_list(recorded, 'consumers')
        added = @graph.consumers_of(source.name).reject { |node| recorded.include?(node.name) }
        added.each do |node|
          stale_diagnostic(node.path, "#{producer} facts have not observed this consumer of #{source.name}; " \
                                      'run `archspec reflect`')
        end
        added.any?
      end

      # Only calls owned by constants that receiver facts name are indexed.
      def receiverless_calls
        @receiverless_calls ||= begin
          sources = Array(@document['receivers']).filter_map { |entry| entry['source'].to_s.delete_prefix('::') if entry.is_a?(Hash) }.to_set
          @graph.edges.each_with_object(Set.new) do |edge, calls|
            next unless sources.include?(edge.from_constant) && edge.type == :calls_named_method && edge.receiver == :none

            calls << [edge.from_constant, edge.from_path, edge.to, edge.location]
          end
        end
      end

      def validate_envelope
        unless @document.is_a?(Hash) && @document['version'].is_a?(Integer) && [1, VERSION].include?(@document['version'])
          invalid("expected version 1 or #{VERSION}")
        end
        legacy = @document['version'] == 1
        lists = legacy ? LEGACY_LIST_KEYS : LIST_KEYS
        keys = (legacy ? LEGACY_ENVELOPE_KEYS : ENVELOPE_KEYS) + lists
        invalid('unknown document fields') unless (@document.keys - keys).empty?
        string(@document['producer'], 'producer')
        unless @document['environment'].nil? || @document['environment'].is_a?(String)
          invalid('expected an environment string')
        end
        invalid('expected fact lists') unless lists.all? { |key| @document[key].nil? || @document[key].is_a?(Array) }
        validate_freshness_fields unless legacy
      end

      def validate_freshness_fields
        env = @document['env']
        unless env.nil? || (env.is_a?(Hash) && env.all? { |key, value| key.is_a?(String) && value.is_a?(String) })
          invalid('expected env to map variable names to strings')
        end
        %w[inputs sources].each do |key|
          string_list(@document[key], "#{key} patterns") unless @document[key].nil?
        end
        snapshot = @document['snapshot']
        return if snapshot.nil?

        unless snapshot.is_a?(Hash) && snapshot.all? { |key, value| key.is_a?(String) && value.is_a?(String) }
          invalid('expected a snapshot of file digests')
        end
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
        MethodSignature.new(
          counts.fetch(:required),
          counts.fetch(:optional),
          flags.fetch(:rest),
          keywords.fetch(:keywords),
          keywords.fetch(:optional_keywords),
          flags.fetch(:keyword_rest),
          flags.fetch(:block),
          flags.fetch(:forward)
        )
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

      # Every cited file must be analyzed and, in a version 2 snapshot,
      # fingerprinted, so a later edit to it is always detected.
      def project_path(value)
        invalid('invalid source path') unless value.is_a?(String) && !Pathname(value).absolute?
        expanded = File.expand_path(value, @graph.root)
        invalid("source path #{value} is not analyzed") unless @graph.files.key?(expanded)
        snapshot = @document['snapshot']
        if @document['version'] != 1 && snapshot && !snapshot.key?(value)
          invalid("the snapshot does not fingerprint #{value}")
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
