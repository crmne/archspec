# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'
require 'prism'
require 'yaml'

require_relative 'error'
require_relative 'model'
require_relative 'source_location'
require_relative 'value_object'
require_relative 'version'

module ArchSpec
  # What a snapshot was taken from: enough to refuse a comparison between two
  # graphs that were not produced the same way, before a single diagnostic is
  # compared. The rule ids are the rules that existed when the graph was
  # taken, so a rule declared since can be told apart from one that was
  # already failing.
  Receipt = ValueObject.define(
    :format,
    :archspec_version,
    :root,
    :definition_digest,
    :patterns,
    :parsed_set_digest,
    :rule_ids,
    :finding_ids,
    :commit,
    :dirty,
    :payload_digest
  ) do
    # The first reason this receipt cannot be compared with +other+, or nil
    # when the two snapshots were produced the same way. Only the inputs that
    # change what a graph holds are compared: a different commit is what a
    # comparison is for, and a different architecture file is how a rule gets
    # declared, which the delta reports rather than refuses.
    def incomparable_with(other)
      if format != other.format
        "the snapshot format is #{other.format}, this version writes #{format}"
      elsif archspec_version != other.archspec_version
        "the snapshot was taken with archspec #{other.archspec_version}, this is #{archspec_version}"
      elsif root != other.root
        "the snapshot was taken at #{other.root}, this root is #{root}"
      elsif patterns != other.patterns
        'the source or ignore patterns changed since the snapshot was taken'
      end
    end
  end

  # The analysed graph and its receipt, written to a directory so a later
  # +check --baseline+ has a before to grade against. Everything the evaluator
  # reads is stored; everything it can recompute is not. The files are sorted
  # YAML with no timestamp, so two snapshots of the same tree are identical.
  #
  # The graph is written twice: as YAML, which a person can read and which any
  # version can load, and as a Marshal payload of the same document, which
  # loads in a fraction of the time and is what a path-scoped check reads.
  # The receipt records the payload's digest, so a payload that does not
  # match its receipt, or was written by another gem or parser version, is
  # ignored in favour of the YAML rather than trusted.
  class Snapshot
    FORMAT = 1
    DEFAULT_DIRECTORY = '.archspec'
    GRAPH_FILE = 'graph.yml'
    PAYLOAD_FILE = 'graph.bin'
    RECEIPT_FILE = 'receipt.yml'

    attr_reader :graph, :receipt

    def self.write(directory, graph:, definition:, definition_digest:, commit:, dirty:)
      directory = File.expand_path(directory, graph.root)
      document = graph_document(graph)
      payload = Marshal.dump(payload_document(document))
      receipt = receipt_for(graph, definition, definition_digest: definition_digest, commit: commit, dirty: dirty,
                                               payload_digest: Digest::SHA256.hexdigest(payload))

      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, '.gitignore'), "*\n")
      File.write(File.join(directory, RECEIPT_FILE), receipt_document(receipt).to_yaml)
      File.write(File.join(directory, GRAPH_FILE), document.to_yaml)
      File.binwrite(File.join(directory, PAYLOAD_FILE), payload)
      new(graph, receipt)
    rescue SystemCallError => e
      raise Error, "could not write snapshot to #{directory}: #{e.message}"
    end

    def self.load(directory, root:)
      directory = File.expand_path(directory, root)
      receipt_path = File.join(directory, RECEIPT_FILE)
      graph_path = File.join(directory, GRAPH_FILE)
      unless File.exist?(receipt_path) && File.exist?(graph_path)
        raise Error, "no snapshot at #{directory}; run `archspec snapshot` first"
      end

      receipt = receipt_from(read_yaml(receipt_path), receipt_path)
      document, cause = read_payload(File.join(directory, PAYLOAD_FILE), receipt)
      if document.nil?
        yield cause if block_given?
        document = read_yaml(graph_path)
      end
      new(graph_from(document, graph_path, root: receipt.root), receipt, digests_from(document))
    end

    # The snapshot from its payload alone, or nil when there is no payload the
    # current gem and parser wrote matching the receipt. A path-scoped check
    # reuses a snapshot only through this loader, because loading the YAML
    # costs more than parsing a small tree, and a scoped run that is slower
    # than a full one is no loop.
    def self.load_payload(directory, root:)
      directory = File.expand_path(directory, root)
      receipt_path = File.join(directory, RECEIPT_FILE)
      return unless File.exist?(receipt_path)

      receipt = receipt_from(read_yaml(receipt_path), receipt_path)
      document, = read_payload(File.join(directory, PAYLOAD_FILE), receipt)
      return unless document

      new(graph_from(document, PAYLOAD_FILE, root: receipt.root), receipt, digests_from(document))
    end

    def self.payload?(directory, root:)
      !load_payload(directory, root: root).nil?
    rescue Error
      false
    end

    # What the rules said about this graph when it was taken, as fingerprints.
    # A finding the current rules raise on the same graph that is not here was
    # declared since, so a widened cannot_use or a new rule reads as declared
    # rather than carried, without the receipt having to know rule identities.
    def self.finding_ids(graph, definition)
      definition.rules.flat_map { |rule| rule.evaluate(graph) }.map { |d| d.fingerprint(root: graph.root) }.uniq.sort
    end

    def self.receipt_for(graph, definition, definition_digest:, commit:, dirty:, payload_digest: nil)
      Receipt.new(
        format: FORMAT,
        archspec_version: ArchSpec::VERSION,
        root: graph.root,
        definition_digest: definition_digest,
        patterns: (definition.analysis_patterns + definition.ignore_patterns).sort,
        parsed_set_digest: parsed_set_digest(graph),
        rule_ids: definition.rules.map(&:id).uniq.sort,
        finding_ids: finding_ids(graph, definition),
        commit: commit,
        dirty: dirty,
        payload_digest: payload_digest
      )
    end

    def self.parsed_set_digest(graph)
      entries = graph.files.values.sort_by(&:relative_path).map do |file|
        "#{file.relative_path}\0#{content_digest(file.path)}"
      end
      Digest::SHA256.hexdigest(entries.join("\n"))
    end

    def self.content_digest(path)
      Digest::SHA256.file(path).hexdigest
    rescue SystemCallError
      ''
    end

    def initialize(graph, receipt, digests = nil)
      @graph = graph
      @receipt = receipt
      @digests = digests
    end

    # Root-relative paths whose content differs from what the snapshot read,
    # including files the snapshot never saw. Nil when the snapshot carries
    # no digests. Read from the files themselves, so a tree that was dirty
    # when the snapshot was taken compares against what was actually read,
    # not against a commit.
    def changed_files(current_graph)
      return if @digests.nil?

      current_graph.files.values.each_with_object(Set.new) do |file, changed|
        digest = self.class.content_digest(file.path)
        changed.add(file.relative_path) unless @digests[file.relative_path] == digest
      end
    end

    class << self
      private

      def read_yaml(path)
        YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: false)
      rescue Psych::Exception, SystemCallError => e
        raise Error, "could not load snapshot file #{path}: #{e.message}"
      end

      def payload_document(document)
        { 'format' => FORMAT, 'archspec_version' => ArchSpec::VERSION, 'prism_version' => Prism::VERSION,
          'graph' => document }
      end

      # The graph document from the payload, or nil when there is none, when it
      # does not match the receipt's digest, or when another gem or parser
      # version wrote it. Every refusal falls back to the YAML silently: the
      # payload is an accelerator, never the record.
      def read_payload(path, receipt)
        return [nil, 'the snapshot has no payload'] unless receipt.payload_digest && File.exist?(path)

        bytes = File.binread(path)
        return [nil, 'the payload does not match its receipt'] unless Digest::SHA256.hexdigest(bytes) == receipt.payload_digest

        payload = Marshal.load(bytes)
        unless payload.is_a?(Hash) && payload['format'] == FORMAT
          return [nil, 'the payload was written in another snapshot format']
        end
        unless payload['archspec_version'] == ArchSpec::VERSION && payload['prism_version'] == Prism::VERSION
          return [nil, "the payload was written by archspec #{payload['archspec_version']} with prism #{payload['prism_version']}"]
        end

        [payload['graph'], nil]
      rescue ArgumentError, TypeError, SystemCallError => e
        [nil, "the payload could not be read: #{e.message}"]
      end

      def digests_from(document)
        files = Array(document['files'])
        return unless files.all? { |file| file.key?('digest') }

        files.to_h { |file| [file.fetch('path'), file.fetch('digest')] }
      end

      def receipt_document(receipt)
        {
          'format' => receipt.format,
          'archspec_version' => receipt.archspec_version,
          'root' => receipt.root,
          'definition_digest' => receipt.definition_digest,
          'patterns' => receipt.patterns,
          'parsed_set_digest' => receipt.parsed_set_digest,
          'rule_ids' => receipt.rule_ids,
          'finding_ids' => receipt.finding_ids,
          'commit' => receipt.commit,
          'dirty' => receipt.dirty,
          'payload_digest' => receipt.payload_digest
        }
      end

      def receipt_from(document, path)
        raise Error, "invalid snapshot receipt #{path}: expected a mapping" unless document.is_a?(Hash)

        Receipt.new(
          format: document['format'],
          archspec_version: document['archspec_version'].to_s,
          root: document['root'].to_s,
          definition_digest: document['definition_digest'],
          patterns: Array(document['patterns']).map(&:to_s),
          parsed_set_digest: document['parsed_set_digest'].to_s,
          rule_ids: Array(document['rule_ids']).map(&:to_s),
          finding_ids: Array(document['finding_ids']).map(&:to_s),
          commit: document['commit'],
          dirty: document['dirty'] == true,
          payload_digest: document['payload_digest']
        )
      end

      def graph_document(graph)
        root = graph.root
        {
          'files' => graph.files.values.sort_by(&:relative_path).map { |file| file_document(file) },
          'constants' => graph.constants.map { |constant| constant_document(constant, root) },
          'edges' => graph.edges.map { |edge| edge_document(edge, graph, root) },
          'components' => graph.components.values.map { |component| component_document(component, root) },
          'externals' => graph.externals.map { |node| external_document(node) },
          'ancestors' => graph.engine_ancestry_documents,
          'aliases' => graph.aliases.map { |declaration| alias_document(declaration, root) },
          'diagnostics' => graph.engine_diagnostics.map { |rule, path, line| [rule, relative(path, root), line] }
        }
      end

      def external_document(node)
        {
          'name' => node.name,
          'kind' => node.kind.to_s,
          'origin' => node.external,
          'instance_methods' => node.instance_methods.map(&:to_s).sort,
          'class_methods' => node.class_methods.map(&:to_s).sort
        }
      end

      def alias_document(declaration, root)
        {
          'owner' => declaration.owner,
          'kind' => declaration.kind.to_s,
          'name' => declaration.name,
          'target' => declaration.target,
          'location' => [relative(declaration.location.path, root), declaration.location.line]
        }
      end

      def file_document(file)
        {
          'path' => file.relative_path,
          'digest' => content_digest(file.path),
          'parse_errors' => file.parse_errors.map do |error|
            { 'message' => error.message, 'location' => location_document(error.location) }
          end,
          'suppressions' => file.suppressions.map do |suppression|
            {
              'rule' => suppression.rule,
              'start_line' => suppression.start_line,
              'end_line' => finite_line(suppression.end_line),
              'reason' => suppression.reason
            }
          end
        }
      end

      def constant_document(constant, root)
        {
          'name' => constant.name,
          'kind' => constant.kind.to_s,
          'path' => relative(constant.path, root),
          'location' => location_document(constant.location),
          'nesting' => constant.nesting.to_a,
          'superclass' => constant.superclass,
          'methods' => constant.method_definitions.map do |definition|
            {
              'name' => definition.name.to_s,
              'scope' => definition.scope.to_s,
              'location' => location_document(definition.location),
              'visibility' => definition.visibility.to_s,
              'signature' => definition.signature&.to_a
            }
          end,
          'mixins' => constant.mixins.transform_keys(&:to_s).transform_values { |names| names.to_a.sort }
        }
      end

      def edge_document(edge, graph, root)
        {
          'type' => edge.type.to_s,
          'from_path' => relative(edge.from_path, root),
          'from_constant' => edge.from_constant,
          'to' => edge.to,
          'location' => location_document(edge.location),
          'confidence' => edge.confidence.to_s,
          'receiver' => edge.receiver&.to_s,
          'lexical_nesting' => edge.lexical_nesting&.to_a,
          'receiver_constant' => edge.receiver_constant,
          'facts_file' => graph.facts_file_for(edge)
        }
      end

      def component_document(component, root)
        {
          'name' => component.name.to_s,
          'files' => component.files.map { |path| relative(path, root) }.sort,
          'constants' => component.constant_occurrences.map { |name, path| [name, relative(path, root)] }.sort,
          'externals' => component.externals.to_a.sort
        }
      end

      def location_document(location)
        [location.line, location.column, location.end_line, location.end_column]
      end

      def finite_line(line)
        line.is_a?(Float) && line.infinite? ? nil : line
      end

      def relative(path, root)
        Pathname(path).relative_path_from(Pathname(root)).to_s
      end

      def graph_from(document, path, root:)
        raise Error, "invalid snapshot graph #{path}: expected a mapping" unless document.is_a?(Hash)

        graph = Graph.new(root)
        Array(document['files']).each { |file| restore_file(graph, file, root) }
        Array(document['constants']).each { |constant| restore_constant(graph, constant, root) }
        Array(document['externals']).each do |external|
          graph.add_external(name: external.fetch('name'), kind: external.fetch('kind'), origin: external.fetch('origin'),
                             instance_methods: Array(external['instance_methods']), class_methods: Array(external['class_methods']))
        end
        Array(document['ancestors']).each do |owner, chains|
          graph.record_ancestors(owner, instance: Array(chains['instance']), class_side: Array(chains['class']))
        end
        Array(document['aliases']).each do |entry|
          file, line = entry.fetch('location')
          absolute = File.expand_path(file, root)
          graph.add_alias(AliasDeclaration.new(entry.fetch('owner'), entry.fetch('kind').to_sym, entry.fetch('name'),
                                               entry.fetch('target'), SourceLocation.point(absolute, line, 1)))
        end
        Array(document['diagnostics']).each do |rule, file, line|
          graph.record_engine_diagnostic(rule: rule, path: File.expand_path(file, root), line: line)
        end
        Array(document['edges']).each { |edge| restore_edge(graph, edge, root) }
        graph.restore_components(Array(document['components']).map { |component| restored_component(component, root) })
        graph
      rescue KeyError, TypeError, NoMethodError => e
        raise Error, "invalid snapshot graph #{path}: #{e.message}"
      end

      def restore_file(graph, file, root)
        absolute = File.expand_path(file.fetch('path'), root)
        graph.add_file(
          path: absolute,
          parse_errors: Array(file['parse_errors']).map do |error|
            ParseError.new(error.fetch('message'), restored_location(absolute, error.fetch('location')))
          end,
          suppressions: Array(file['suppressions']).map do |suppression|
            Suppression.new(
              suppression['rule'],
              suppression.fetch('start_line'),
              suppression['end_line'] || Float::INFINITY,
              suppression['reason']
            )
          end
        )
      end

      def restore_constant(graph, document, root)
        absolute = File.expand_path(document.fetch('path'), root)
        held = ConstantNode.new(
          name: document.fetch('name'),
          kind: document.fetch('kind').to_sym,
          path: absolute,
          location: restored_location(absolute, document.fetch('location')),
          nesting: Array(document['nesting'])
        )
        held.superclass = document['superclass']
        Array(document['methods']).each do |definition|
          location = restored_location(absolute, definition.fetch('location'))
          visibility = definition.fetch('visibility').to_sym
          signature = definition['signature'] && Signature.new(*definition['signature'])
          if definition.fetch('scope') == 'class'
            held.add_class_method(definition.fetch('name'), location: location, visibility: visibility, signature: signature)
          else
            held.add_instance_method(definition.fetch('name'), location: location, visibility: visibility, signature: signature)
          end
        end
        Hash(document['mixins']).each do |kind, names|
          Array(names).each { |name| held.add_mixin(kind.to_sym, name) }
        end
        graph.copy_constant(held)
      end

      def restore_edge(graph, document, root)
        absolute = File.expand_path(document.fetch('from_path'), root)
        graph.add_edge(
          type: document.fetch('type').to_sym,
          from_path: absolute,
          from_constant: document['from_constant'],
          to: document.fetch('to'),
          location: restored_location(absolute, document.fetch('location')),
          confidence: document.fetch('confidence').to_sym,
          receiver: document['receiver']&.to_sym,
          lexical_nesting: document['lexical_nesting'],
          receiver_constant: document['receiver_constant']
        )
        graph.record_facts_origin(graph.edges.last, document['facts_file']) if document['facts_file']
      end

      def restored_component(document, root)
        component = Component.new(document.fetch('name'))
        Array(document['files']).each { |file| component.add_file(File.expand_path(file, root)) }
        Array(document['constants']).each do |name, file|
          component.add_constant(name, path: File.expand_path(file, root))
        end
        Array(document['externals']).each { |name| component.add_external(name) }
        component
      end

      def restored_location(path, values)
        line, column, end_line, end_column = values
        SourceLocation.new(path, line, column, end_line, end_column)
      end
    end
  end

  # Reads the working tree through the git binary. Every reader answers nil
  # when git is absent or the root is not a repository, and the caller says
  # so; a missing answer is never read as an empty one.
  module GitTree
    extend self

    def commit(root)
      git(root, 'rev-parse', 'HEAD')
    end

    def dirty?(root)
      status = git(root, 'status', '--porcelain')
      status.nil? ? false : !status.empty?
    end

    # Root-relative paths that differ between +commit+ and the working tree,
    # including files not yet added. Nil when git cannot answer.
    def changed_files(root, commit)
      return if commit.nil? || commit.empty?

      diff = git(root, 'diff', '--name-only', '--relative', commit)
      untracked = git(root, 'ls-files', '--others', '--exclude-standard')
      return if diff.nil? || untracked.nil?

      (diff.lines + untracked.lines).map(&:strip).reject(&:empty?).to_set
    end

    private

    def git(root, *args)
      result = IO.popen(['git', '-C', root, *args], err: File::NULL, &:read)
      $?.success? ? result.strip : nil
    rescue SystemCallError
      nil
    end
  end
end
