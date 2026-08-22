# frozen_string_literal: true

require 'pathname'
require 'fileutils'
require 'yaml'

require_relative 'value_object'

module ArchSpec
  FactsReference = ValueObject.define(:owner, :file, :line, :target, :macro, :name, :determination)
  FactsGeneratedMethods = ValueObject.define(:owner, :names)
  FactsAncestry = ValueObject.define(:owner, :kind, :target, :file, :line, :determination)
  FactsDefinition = ValueObject.define(:owner, :name, :scope, :visibility, :file, :line, :determination)
  FactsCall = ValueObject.define(:owner, :file, :line, :method, :receiver, :determination)

  FactsFile = ValueObject.define(
    :path,
    :relative_path,
    :producer,
    :producer_version,
    :commit,
    :dirty,
    :references,
    :generated_methods,
    :ancestry,
    :definitions,
    :calls,
    :misses
  ) do
    def entries
      counts.values.sum
    end

    def counts
      {
        references: references.size,
        generated_methods: generated_methods.size,
        ancestry: ancestry.size,
        definitions: definitions.size,
        calls: calls.size
      }
    end
  end

  # A directory of facts files, each written by a producer that knows
  # something the parser cannot see, such as the class an Active Record
  # association resolves to. ArchSpec merges every file before rules run and
  # never guesses what a file does not state: an unknown key, entry, or
  # format version is an error naming the file, and a directory that is not
  # there is reported as absent rather than read as clean. Format 2 added
  # ancestry, definitions and calls; a format 1 file is read as format 2
  # with those lists empty, since a producer that wrote it stated nothing
  # about them.
  class Facts
    FORMAT = 2
    FORMATS = [1, 2].freeze
    DEFAULT_DIRECTORY = 'archspec_facts'
    FILE_KEYS = %w[format producer producer_version commit dirty references generated_methods
                   ancestry definitions calls misses].freeze
    REQUIRED_FILE_KEYS = %w[format producer producer_version references generated_methods].freeze
    REFERENCE_KEYS = %w[owner file line target macro name determination].freeze
    REQUIRED_REFERENCE_KEYS = %w[owner file line target].freeze
    GENERATED_METHODS_KEYS = %w[owner names].freeze
    ANCESTRY_KEYS = %w[owner kind target file line determination].freeze
    REQUIRED_ANCESTRY_KEYS = %w[owner kind target file line].freeze
    ANCESTRY_KINDS = %w[inherits includes prepends extends].freeze
    DEFINITION_KEYS = %w[owner name scope visibility file line determination].freeze
    REQUIRED_DEFINITION_KEYS = %w[owner name scope file line].freeze
    SCOPES = %w[instance class].freeze
    VISIBILITIES = %w[public private protected].freeze
    CALL_KEYS = %w[owner file line method receiver determination].freeze
    REQUIRED_CALL_KEYS = %w[owner file line method receiver].freeze

    attr_reader :files, :directory

    def self.empty(directory: nil)
      new([], directory: directory, present: false)
    end

    def self.load(directory, root:)
      directory = File.expand_path(directory, root)
      return empty(directory: directory) unless File.directory?(directory)

      files = Dir.glob(File.join(directory, '*.{yml,yaml}')).sort.map { |path| load_file(path, root: root) }
      new(files, directory: directory, present: true)
    end

    def self.load_file(path, root:)
      document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      raise Error, "invalid facts file #{path}: expected a mapping" unless document.is_a?(Hash)

      unknown = document.keys - FILE_KEYS
      raise Error, "invalid facts file #{path}: unknown key #{unknown.first.inspect}" if unknown.any?

      missing = REQUIRED_FILE_KEYS - document.keys
      raise Error, "invalid facts file #{path}: missing key #{missing.first.inspect}" if missing.any?

      unless FORMATS.include?(document['format'])
        raise Error, "invalid facts file #{path}: format #{document['format'].inspect} is not #{FORMAT}"
      end

      FactsFile.new(
        path: path,
        relative_path: Pathname(path).relative_path_from(Pathname(root)).to_s,
        producer: string!(path, 'producer', document['producer']),
        producer_version: string!(path, 'producer_version', document['producer_version']),
        commit: document['commit'].nil? ? nil : string!(path, 'commit', document['commit']),
        dirty: boolean!(path, 'dirty', document['dirty']),
        references: references!(path, document['references']),
        generated_methods: generated_methods!(path, document['generated_methods']),
        ancestry: ancestry!(path, document.fetch('ancestry', [])),
        definitions: definitions!(path, document.fetch('definitions', [])),
        calls: calls!(path, document.fetch('calls', [])),
        misses: misses!(path, document['misses'])
      )
    rescue Error
      raise
    rescue Psych::Exception, SystemCallError => e
      raise Error, "could not load facts file #{path}: #{e.message}"
    end

    def self.write_to(path, root:, **facts)
      FileUtils.mkdir_p(File.dirname(path))
      write(path, commit: commit_for(root), dirty: dirty?(root), **facts)
    end

    def self.write(path, producer:, producer_version:, commit:, dirty:, references:, generated_methods:, misses:,
                   ancestry: [], definitions: [], calls: [])
      payload = {
        'format' => FORMAT,
        'producer' => producer,
        'producer_version' => producer_version,
        'commit' => commit,
        'dirty' => dirty,
        'references' => references.sort_by { |entry| [entry.owner, entry.name.to_s, entry.target] }.map do |entry|
          {
            'owner' => entry.owner,
            'file' => entry.file,
            'line' => entry.line,
            'target' => entry.target,
            'macro' => entry.macro,
            'name' => entry.name,
            'determination' => entry.determination
          }.compact
        end,
        'generated_methods' => generated_methods.sort_by(&:owner).map do |entry|
          { 'owner' => entry.owner, 'names' => entry.names.map(&:to_s).sort }
        end,
        'ancestry' => ancestry.sort_by { |entry| [entry.owner, entry.kind, entry.target] }.map do |entry|
          {
            'owner' => entry.owner,
            'kind' => entry.kind,
            'target' => entry.target,
            'file' => entry.file,
            'line' => entry.line,
            'determination' => entry.determination
          }.compact
        end,
        'definitions' => definitions.sort_by { |entry| [entry.owner, entry.scope, entry.name] }.map do |entry|
          {
            'owner' => entry.owner,
            'name' => entry.name,
            'scope' => entry.scope,
            'visibility' => entry.visibility,
            'file' => entry.file,
            'line' => entry.line,
            'determination' => entry.determination
          }.compact
        end,
        'calls' => calls.sort_by { |entry| [entry.owner, entry.file, entry.line, entry.method, entry.receiver] }.map do |entry|
          {
            'owner' => entry.owner,
            'file' => entry.file,
            'line' => entry.line,
            'method' => entry.method,
            'receiver' => entry.receiver,
            'determination' => entry.determination
          }.compact
        end,
        'misses' => misses.sort.to_h
      }

      File.write(path, payload.to_yaml)
    rescue SystemCallError => e
      raise Error, "could not write facts file #{path}: #{e.message}"
    end

    # A file built in memory by a producer that ran inside check, merged
    # beside the files read from disk and reported under the name it gives.
    def self.built(producer:, producer_version:, references:, generated_methods:, misses:, label:,
                   ancestry: [], definitions: [], calls: [])
      FactsFile.new(
        path: nil,
        relative_path: label,
        producer: producer,
        producer_version: producer_version,
        commit: nil,
        dirty: false,
        references: references,
        generated_methods: generated_methods,
        ancestry: ancestry,
        definitions: definitions,
        calls: calls,
        misses: misses
      )
    end

    def self.commit_for(root)
      git(root, 'rev-parse', 'HEAD')
    end

    def self.dirty?(root)
      status = git(root, 'status', '--porcelain')
      !status.nil? && !status.empty?
    end

    def self.git(root, *args)
      result = IO.popen(['git', '-C', root, *args], err: File::NULL, &:read)
      $?.success? ? result.strip : nil
    rescue SystemCallError
      nil
    end

    def initialize(files, directory:, present:)
      @files = files
      @directory = directory
      @present = present
    end

    def with_file(file)
      self.class.new(files + [file], directory: directory, present: @present)
    end

    def present?
      @present
    end

    def references
      files.flat_map(&:references)
    end

    def generated_methods
      files.flat_map(&:generated_methods)
    end

    def ancestry
      files.flat_map(&:ancestry)
    end

    def definitions
      files.flat_map(&:definitions)
    end

    def calls
      files.flat_map(&:calls)
    end

    class << self
      private

      def references!(path, entries)
        raise Error, "invalid facts file #{path}: references must be a list" unless entries.is_a?(Array)

        entries.map.with_index(1) do |entry, index|
          fields!(path, 'reference', index, entry, REFERENCE_KEYS, REQUIRED_REFERENCE_KEYS)
          unless entry['line'].is_a?(Integer) && entry['line'].positive?
            raise Error, "invalid facts file #{path}: reference #{index} has no line"
          end

          FactsReference.new(
            owner: string!(path, 'owner', entry['owner']),
            file: string!(path, 'file', entry['file']),
            line: entry['line'],
            target: string!(path, 'target', entry['target']),
            macro: entry['macro']&.to_s,
            name: entry['name']&.to_s,
            determination: entry['determination']&.to_s
          )
        end
      end

      def generated_methods!(path, entries)
        raise Error, "invalid facts file #{path}: generated_methods must be a list" unless entries.is_a?(Array)

        entries.map.with_index(1) do |entry, index|
          fields!(path, 'generated_methods entry', index, entry, GENERATED_METHODS_KEYS, GENERATED_METHODS_KEYS)
          names = entry['names']
          unless names.is_a?(Array) && names.all? { |name| name.is_a?(String) && !name.empty? }
            raise Error, "invalid facts file #{path}: generated_methods entry #{index} needs a list of names"
          end

          FactsGeneratedMethods.new(owner: string!(path, 'owner', entry['owner']), names: names.map(&:to_sym))
        end
      end

      def boolean!(path, field, value)
        return false if value.nil?
        return value if value == true || value == false

        raise Error, "invalid facts file #{path}: #{field} must be true or false"

      def ancestry!(path, entries)
        raise Error, "invalid facts file #{path}: ancestry must be a list" unless entries.is_a?(Array)

        entries.map.with_index(1) do |entry, index|
          fields!(path, 'ancestry entry', index, entry, ANCESTRY_KEYS, REQUIRED_ANCESTRY_KEYS)
          line!(path, 'ancestry entry', index, entry['line'])
          one_of!(path, 'ancestry entry', index, 'kind', entry['kind'], ANCESTRY_KINDS)

          FactsAncestry.new(
            owner: string!(path, 'owner', entry['owner']),
            kind: entry['kind'],
            target: string!(path, 'target', entry['target']),
            file: string!(path, 'file', entry['file']),
            line: entry['line'],
            determination: entry['determination']&.to_s
          )
        end
      end

      def definitions!(path, entries)
        raise Error, "invalid facts file #{path}: definitions must be a list" unless entries.is_a?(Array)

        entries.map.with_index(1) do |entry, index|
          fields!(path, 'definition', index, entry, DEFINITION_KEYS, REQUIRED_DEFINITION_KEYS)
          line!(path, 'definition', index, entry['line'])
          one_of!(path, 'definition', index, 'scope', entry['scope'], SCOPES)
          visibility = entry.fetch('visibility', 'public')
          one_of!(path, 'definition', index, 'visibility', visibility, VISIBILITIES)

          FactsDefinition.new(
            owner: string!(path, 'owner', entry['owner']),
            name: string!(path, 'name', entry['name']),
            scope: entry['scope'],
            visibility: visibility,
            file: string!(path, 'file', entry['file']),
            line: entry['line'],
            determination: entry['determination']&.to_s
          )
        end
      end

      def calls!(path, entries)
        raise Error, "invalid facts file #{path}: calls must be a list" unless entries.is_a?(Array)

        entries.map.with_index(1) do |entry, index|
          fields!(path, 'call', index, entry, CALL_KEYS, REQUIRED_CALL_KEYS)
          line!(path, 'call', index, entry['line'])

          FactsCall.new(
            owner: string!(path, 'owner', entry['owner']),
            file: string!(path, 'file', entry['file']),
            line: entry['line'],
            method: string!(path, 'method', entry['method']),
            receiver: string!(path, 'receiver', entry['receiver']),
            determination: entry['determination']&.to_s
          )
        end
      end

      def line!(path, label, index, line)
        return if line.is_a?(Integer) && line.positive?

        raise Error, "invalid facts file #{path}: #{label} #{index} has no line"
      end

      def one_of!(path, label, index, key, value, allowed)
        return if allowed.include?(value)

        raise Error, "invalid facts file #{path}: #{label} #{index} has #{key} #{value.inspect}, not one of #{allowed.join(', ')}"
      end

      def misses!(path, counts)
        return {} if counts.nil?
        raise Error, "invalid facts file #{path}: misses must be a mapping" unless counts.is_a?(Hash)

        counts.each do |cause, count|
          next if cause.is_a?(String) && count.is_a?(Integer)

          raise Error, "invalid facts file #{path}: misses must map a cause to a count"
        end
      end

      def fields!(path, label, index, entry, allowed, required)
        raise Error, "invalid facts file #{path}: #{label} #{index} is not a mapping" unless entry.is_a?(Hash)

        unknown = entry.keys - allowed
        raise Error, "invalid facts file #{path}: #{label} #{index} has unknown field #{unknown.first.inspect}" if unknown.any?

        missing = required - entry.keys
        raise Error, "invalid facts file #{path}: #{label} #{index} is missing #{missing.first.inspect}" if missing.any?
      end

      def string!(path, key, value)
        raise Error, "invalid facts file #{path}: #{key} must be a non-empty string" unless value.is_a?(String) && !value.empty?

        value
      end
    end
  end
end
