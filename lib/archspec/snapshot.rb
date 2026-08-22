# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'
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
    :commit,
    :dirty
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
  class Snapshot
    FORMAT = 1
    DEFAULT_DIRECTORY = '.archspec'
    GRAPH_FILE = 'graph.yml'
    RECEIPT_FILE = 'receipt.yml'

    attr_reader :graph, :receipt

    def self.write(directory, graph:, definition:, definition_digest:, commit:, dirty:)
      directory = File.expand_path(directory, graph.root)
      receipt = receipt_for(graph, definition, definition_digest: definition_digest, commit: commit, dirty: dirty)

      FileUtils.mkdir_p(directory)
      File.write(File.join(directory, '.gitignore'), "*\n")
      File.write(File.join(directory, RECEIPT_FILE), receipt_document(receipt).to_yaml)
      File.write(File.join(directory, GRAPH_FILE), graph_document(graph).to_yaml)
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
      graph = graph_from(read_yaml(graph_path), graph_path, root: receipt.root)
      new(graph, receipt)
    end

    def self.receipt_for(graph, definition, definition_digest:, commit:, dirty:)
      Receipt.new(
        format: FORMAT,
        archspec_version: ArchSpec::VERSION,
        root: graph.root,
        definition_digest: definition_digest,
        patterns: (definition.analysis_patterns + definition.ignore_patterns).sort,
        parsed_set_digest: parsed_set_digest(graph),
        rule_ids: definition.rules.map(&:id).uniq.sort,
        commit: commit,
        dirty: dirty
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

    def initialize(graph, receipt)
      @graph = graph
      @receipt = receipt
    end

    class << self
      private

      def read_yaml(path)
        YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: false)
      rescue Psych::Exception, SystemCallError => e
        raise Error, "could not load snapshot file #{path}: #{e.message}"
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
          'commit' => receipt.commit,
          'dirty' => receipt.dirty
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
          commit: document['commit'],
          dirty: document['dirty'] == true
        )
      end

      def graph_document(graph)
        root = graph.root
        {
          'files' => graph.files.values.sort_by(&:relative_path).map { |file| file_document(file) },
          'constants' => graph.constants.map { |constant| constant_document(constant, root) },
          'edges' => graph.edges.map { |edge| edge_document(edge, graph, root) },
          'components' => graph.components.values.map { |component| component_document(component, root) }
        }
      end

      def file_document(file)
        {
          'path' => file.relative_path,
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
              'visibility' => definition.visibility.to_s
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
          'facts_file' => graph.facts_file_for(edge)
        }
      end

      def component_document(component, root)
        {
          'name' => component.name.to_s,
          'files' => component.files.map { |path| relative(path, root) }.sort,
          'constants' => component.constant_occurrences.map { |name, path| [name, relative(path, root)] }.sort
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
        constant = graph.add_constant(
          name: document.fetch('name'),
          kind: document.fetch('kind').to_sym,
          path: absolute,
          location: restored_location(absolute, document.fetch('location')),
          nesting: Array(document['nesting'])
        )
        constant.superclass = document['superclass']
        Array(document['methods']).each do |definition|
          location = restored_location(absolute, definition.fetch('location'))
          visibility = definition.fetch('visibility').to_sym
          if definition.fetch('scope') == 'class'
            constant.add_class_method(definition.fetch('name'), location: location, visibility: visibility)
          else
            constant.add_instance_method(definition.fetch('name'), location: location, visibility: visibility)
          end
        end
        Hash(document['mixins']).each do |kind, names|
          Array(names).each { |name| constant.add_mixin(kind.to_sym, name) }
        end
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
          lexical_nesting: document['lexical_nesting']
        )
        graph.record_facts_origin(graph.edges.last, document['facts_file']) if document['facts_file']
      end

      def restored_component(document, root)
        component = Component.new(document.fetch('name'))
        Array(document['files']).each { |file| component.add_file(File.expand_path(file, root)) }
        Array(document['constants']).each do |name, file|
          component.add_constant(name, path: File.expand_path(file, root))
        end
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
