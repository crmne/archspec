# frozen_string_literal: true

require 'yaml'

module ArchSpec
  # A file of accepted existing violations. ArchSpec still checks the files
  # these come from, but subtracts the recorded violations so you can adopt it
  # in an existing app and burn the list down over time. Matched by
  # ArchSpec::Diagnostic#fingerprint, so entries survive edits that shift lines.
  class Todo
    def self.empty(root: nil)
      new({}, root: root)
    end

    def self.load(path, root:)
      return empty(root: root) unless path && File.exist?(path)

      document = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      unless document.is_a?(Hash) && (document['violations'].nil? || document['violations'].is_a?(Array))
        raise Error, "invalid todo file #{path}: expected a violations list"
      end

      entries = Array(document['violations']).each_with_index.to_h do |entry, index|
        id = entry.is_a?(Hash) ? entry['id'] : entry
        unless id.is_a?(String) && !id.empty?
          raise Error, "invalid todo file #{path}: violation #{index + 1} has no id"
        end

        [id, entry.is_a?(Hash) ? entry : { 'id' => id }]
      end

      new(entries, root: root)
    rescue Error
      raise
    rescue Psych::Exception, SystemCallError => e
      raise Error, "could not load todo file #{path}: #{e.message}"
    end

    def self.write(path, diagnostics, root:)
      entries = diagnostics.map do |diagnostic|
        {
          'id' => diagnostic.fingerprint(root: root),
          'rule' => diagnostic.rule,
          'path' => diagnostic.location.relative_path(root),
          'message' => diagnostic.message,
          'evidence' => diagnostic.evidence
        }
      end
      entries.uniq! { |entry| entry['id'] }
      entries.sort_by! { |entry| entry.values_at('path', 'rule', 'message', 'evidence') }

      File.write(path, { 'violations' => entries }.to_yaml)
      entries.size
    rescue SystemCallError => e
      raise Error, "could not write todo file #{path}: #{e.message}"
    end

    def initialize(entries, root:)
      @entries = entries
      @root = root
    end

    def include?(diagnostic)
      entries.key?(diagnostic.fingerprint(root: root))
    end

    def unmatched_by(diagnostics)
      matched = diagnostics.map { |diagnostic| diagnostic.fingerprint(root: root) }.to_set
      entries.reject { |id, _entry| matched.include?(id) }.values
    end

    private

    attr_reader :entries, :root
  end
end
