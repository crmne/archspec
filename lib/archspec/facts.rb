# frozen_string_literal: true

require 'pathname'
require 'yaml'

require_relative 'value_object'

module ArchSpec
  FactsReference = ValueObject.define(:owner, :file, :line, :target, :macro, :name)
  FactsGeneratedMethods = ValueObject.define(:owner, :names)

  FactsFile = ValueObject.define(
    :path,
    :relative_path,
    :producer,
    :producer_version,
    :commit,
    :dirty,
    :references,
    :generated_methods,
    :misses
  ) do
    def entries
      references.size + generated_methods.size
    end
  end

  # A directory of facts files, each written by a producer that knows
  # something the parser cannot see, such as the class an Active Record
  # association resolves to. ArchSpec merges every file before rules run and
  # never guesses what a file does not state: an unknown key, entry, or
  # format version is an error naming the file, and a directory that is not
  # there is reported as absent rather than read as clean.
  class Facts
    FORMAT = 1
    DEFAULT_DIRECTORY = 'archspec_facts'
    FILE_KEYS = %w[format producer producer_version commit dirty references generated_methods misses].freeze
    REQUIRED_FILE_KEYS = %w[format producer producer_version references generated_methods].freeze
    REFERENCE_KEYS = %w[owner file line target macro name].freeze
    REQUIRED_REFERENCE_KEYS = %w[owner file line target].freeze
    GENERATED_METHODS_KEYS = %w[owner names].freeze

    attr_reader :files, :directory

    def self.empty(directory: nil)
      new([], directory: directory, present: false)
    end

    def self.load(directory, root:)
      directory = File.expand_path(directory, root)
      return empty(directory: directory) unless File.directory?(directory)

      files = Dir.glob(File.join(directory, '*.yml')).sort.map { |path| load_file(path, root: root) }
      new(files, directory: directory, present: true)
    end

    def self.load_file(path, root:)
      document = YAML.safe_load_file(path, permitted_classes: [], aliases: false)
      raise Error, "invalid facts file #{path}: expected a mapping" unless document.is_a?(Hash)

      unknown = document.keys - FILE_KEYS
      raise Error, "invalid facts file #{path}: unknown key #{unknown.first.inspect}" if unknown.any?

      missing = REQUIRED_FILE_KEYS - document.keys
      raise Error, "invalid facts file #{path}: missing key #{missing.first.inspect}" if missing.any?

      unless document['format'] == FORMAT
        raise Error, "invalid facts file #{path}: format #{document['format'].inspect} is not #{FORMAT}"
      end

      FactsFile.new(
        path: path,
        relative_path: Pathname(path).relative_path_from(Pathname(root)).to_s,
        producer: string!(path, 'producer', document['producer']),
        producer_version: string!(path, 'producer_version', document['producer_version']),
        commit: document['commit'].nil? ? nil : string!(path, 'commit', document['commit']),
        dirty: document['dirty'] == true,
        references: references!(path, document['references']),
        generated_methods: generated_methods!(path, document['generated_methods']),
        misses: misses!(path, document['misses'])
      )
    rescue Error
      raise
    rescue Psych::Exception, SystemCallError => e
      raise Error, "could not load facts file #{path}: #{e.message}"
    end

    def self.write(path, producer:, producer_version:, commit:, dirty:, references:, generated_methods:, misses:)
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
            'name' => entry.name
          }.compact
        end,
        'generated_methods' => generated_methods.sort_by(&:owner).map do |entry|
          { 'owner' => entry.owner, 'names' => entry.names.map(&:to_s).sort }
        end,
        'misses' => misses.sort.to_h
      }

      File.write(path, payload.to_yaml)
    rescue SystemCallError => e
      raise Error, "could not write facts file #{path}: #{e.message}"
    end

    def initialize(files, directory:, present:)
      @files = files
      @directory = directory
      @present = present
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
            name: entry['name']&.to_s
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
