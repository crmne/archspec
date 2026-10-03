# frozen_string_literal: true

module ArchSpec
  module Facts
    # Framework-neutral facts, established by source semantics or by reflection.
    # Locations retain the original evidence, even when it lives in a different
    # file from the owner.
    #
    # Owners, sources, and targets can be graph ConstantNodes, constant names,
    # or the runtime classes and modules themselves. Locations can be
    # SourceLocations, <tt>[path, line]</tt> pairs such as
    # <tt>Module#const_source_location</tt> returns, backtrace locations a macro
    # recorded with +caller_locations+, or anything with a +source_location+:
    #
    #   facts.reference(source: Invoice, target: Customer, location: ["app/models/invoice.rb", 3])
    #   facts.methods(owner: "Invoice", names: %w[customer customer=], location: declaration_site)
    #
    # Use #apply for an in-memory semantic pass, or #to_document and Facts.write
    # for an explicit external producer. Both routes use the same validation and
    # application code. Building facts never mutates the graph.
    class Builder
      MODULE_NAME = Module.instance_method(:name)

      attr_reader :graph, :producer

      def initialize(graph, producer:)
        @graph = graph
        @producer = producer.to_s
        @entries = LIST_KEYS.to_h { |key| [key, []] }
      end

      def reference(source:, target:, location:)
        location = location_of(location)
        source = constant(source, location)
        add('references', entry_for(source, location).merge('source' => source.name, 'target' => name_of(target)))
      end

      def methods(owner:, names:, location:, scope: :instance, visibility: :public,
                  signatures: [], alias_target: nil, mode: :if_missing, installation: nil)
        unless alias_target.nil? || alias_target.is_a?(String) || alias_target.is_a?(Symbol)
          raise Error, 'alias target must be a String or Symbol'
        end
        location = location_of(location)
        owner = constant(owner, location)
        entry = entry_for(owner, location).merge('owner' => owner.name, 'names' => Array(names).map(&:to_s),
          'scope' => scope.to_s, 'visibility' => visibility.to_s, 'mode' => mode.to_s,
          'signatures' => signatures.map do |signature|
            signature.to_h.transform_keys(&:to_s).transform_values do |value|
              value.is_a?(Array) ? value.map(&:to_s) : value
            end
          end)
        entry['alias_target'] = alias_target.to_s unless alias_target.nil?
        entry['installation'] = location_for(location_of(installation)) if installation
        add('methods', entry)
      end

      # Preserve a source definition's metadata while installing it on an owner.
      # An installation site gives callback definitions their Ruby precedence:
      # later local definitions win, earlier definitions are replaced.
      def method_definition(owner:, definition:, installation: nil)
        methods(owner: owner, names: [definition.name], scope: definition.scope, location: definition.location,
          visibility: definition.visibility, signatures: definition.signatures, alias_target: definition.alias_target,
          mode: installation ? :define : :append, installation: installation)
      end

      # Emit mixins in installation order, including singleton prepends.
      def mixin(owner:, target:, kind:, location:)
        location = location_of(location)
        owner = constant(owner, location)
        add('mixins', entry_for(owner, location).merge('owner' => owner.name,
          'target' => name_of(target), 'kind' => kind.to_s))
      end

      # Bind an existing receiverless call without changing its lexical owner.
      # Emit every consumer of a shared callback before applying the batch.
      def bind_receiver(edge:, receiver:, scope:)
        source = @graph.constants_named(edge.from_constant).find { |node| node.path == edge.from_path }
        raise Error, 'receiver fact requires a call owned by an analyzed constant' unless source

        add('receivers', entry_for(source, edge.location).merge('source' => source.name,
          'name' => edge.to, 'receiver' => name_of(receiver), 'scope' => scope.to_s))
      end

      def expose_methods(source:, owner:, scope:)
        source = constant(source, nil)
        entry = entry_for(source, source.location).merge('source' => source.name,
          'owner' => name_of(owner), 'scope' => scope.to_s)
        owners = @graph.constants_named(name_of(owner)).map { |node| relative(node.path) }.uniq - [entry['source_path']]
        entry['depends_on'] = owners.sort unless owners.empty?
        add('exposures', entry)
      end

      def gap(source:, message:, location:)
        location = location_of(location)
        source = constant(source, location)
        add('gaps', entry_for(source, location).merge('source' => source.name, 'message' => message))
      end

      # Settle a static analysis gap this producer observed, such as a
      # conditional concern callback. The location is the gap's own location.
      # Pass the +consumers+ you inspected when the gap is about a module's
      # includers: their files are fingerprinted, and a check reports any
      # includer added later instead of keeping the gap settled.
      def resolve(source:, location:, message: nil, consumers: nil)
        location = location_of(location)
        source = constant(source, location)
        entry = entry_for(source, location).merge('source' => source.name)
        entry['message'] = message if message
        if consumers
          nodes = consumers.map { |consumer| constant(consumer, nil) }
          entry['consumers'] = nodes.map(&:name).uniq.sort
          paths = nodes.map { |node| relative(node.path) }.uniq - [entry['source_path'], entry['path']]
          entry['depends_on'] = paths.sort unless paths.empty?
        end
        add('resolves', entry)
      end

      def apply
        document = Document.new(@graph, facts, @producer)
        Application.apply(@graph, [document.compile.with(producer: nil)])
      end

      # Validate before publication, so malformed evidence cannot replace a
      # producer's previous snapshot. +inputs+ are global files whose change
      # invalidates the whole document; +sources+ are patterns of analyzed
      # files whose change invalidates the facts they cite. +env+ records
      # environment variables that must match when a check sets them.
      def to_document(facts_path: 'archspec_facts', inputs: DEFAULT_INPUTS, sources: [], env: {})
        cited = @entries.values.flatten.flat_map do |entry|
          [entry['path'], entry['source_path'], entry.dig('installation', 'path'), *entry['depends_on']]
        end.compact.uniq.map { |path| File.expand_path(path, @graph.root) }
        document = { 'version' => VERSION, 'producer' => @producer,
                     'env' => env.to_h { |name, value| [name.to_s, value.to_s] },
                     'inputs' => inputs.map(&:to_s), 'sources' => sources.map(&:to_s),
                     'snapshot' => Facts.fingerprint(@graph, inputs: inputs, sources: sources, cited: cited,
                                                     excluding: facts_path) }.merge(facts)
        reader = Document.new(@graph, document, @producer)
        Application.validate(@graph, [reader.compile])
        document
      end

      def count(key)
        @entries.fetch(key.to_s).size
      end

      private

      def add(key, entry)
        @entries[key] << entry
        entry
      end

      def facts
        { 'version' => VERSION, 'producer' => @producer }.merge(@entries.transform_values(&:uniq))
      end

      def constant(value, location)
        return value if value.is_a?(ConstantNode)

        name = name_of(value)
        nodes = @graph.constants_named(name)
        raise Error, "#{name} is not an analyzed constant" if nodes.empty?

        candidates = [
          nodes.select { |node| location && node.path == location.path },
          nodes.reject(&:namespace_only),
          nodes
        ]
        match = candidates.find(&:one?)
        raise Error, "#{name} is defined in several files; pass its graph node instead" unless match

        match.first
      end

      def name_of(value)
        name = case value
               when Module then MODULE_NAME.bind_call(value)
               when ConstantNode then value.name
               else value.to_s
               end
        raise Error, 'facts cannot name an anonymous class or module' if name.nil? || name.empty?

        name.delete_prefix('::')
      end

      def location_of(value)
        value = value.source_location if value.respond_to?(:source_location)
        value = [value.path, value.lineno] if value.respond_to?(:lineno) && value.respond_to?(:path)
        case value
        when SourceLocation
          value
        when Array
          path, line = value
          raise Error, "invalid location #{value.inspect}" unless path && line.is_a?(Integer) && line.positive?

          line_location(File.expand_path(path.to_s, @graph.root), line)
        else
          raise Error, "invalid location #{value.inspect}"
        end
      end

      # A line given without columns spans its code, so diagnostics underline
      # the declaration rather than the indentation before it.
      def line_location(path, line)
        text = File.file?(path) ? File.foreach(path).drop(line - 1).first.to_s.chomp : ''
        start = (text.index(/\S/) || 0) + 1
        SourceLocation.new(path, line, start, line, [text.rstrip.bytesize + 1, start].max)
      end

      def entry_for(source, location)
        location_for(location).merge('source_path' => relative(source.path))
      end

      def location_for(location)
        location.to_h.transform_keys(&:to_s).merge('path' => relative(location.path))
      end

      def relative(path)
        Pathname(path).relative_path_from(Pathname(@graph.root)).to_s
      end
    end
  end
end
