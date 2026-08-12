# frozen_string_literal: true

require 'yaml'

module ArchSpec
  # A file of accepted existing violations. ArchSpec still checks the files
  # these come from, but subtracts the recorded violations so you can adopt it
  # in an existing app and burn the list down over time. Matched by
  # ArchSpec::Diagnostic#fingerprint, so entries survive edits that shift lines.
  class Todo
    def self.empty(root: nil)
      new(Set.new, root: root)
    end

    def self.load(path, root:)
      return empty(root: root) unless path && File.exist?(path)

      document = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      unless document.is_a?(Hash) && (document['violations'].nil? || document['violations'].is_a?(Array))
        raise Error, "invalid todo file #{path}: expected a violations list"
      end

      ids = Array(document['violations']).map.with_index do |entry, index|
        id = entry.is_a?(Hash) ? entry['id'] : entry
        unless id.is_a?(String) && !id.empty?
          raise Error, "invalid todo file #{path}: violation #{index + 1} has no id"
        end

        id
      end

      new(ids.to_set, root: root)
    rescue Error
      raise
    rescue Psych::Exception, SystemCallError => e
      raise Error, "could not load todo file #{path}: #{e.message}"
    end

    def self.write(path, diagnostics, root:)
      payload = {
        'violations' => diagnostics.map do |diagnostic|
          {
            'id' => diagnostic.fingerprint(root: root),
            'rule' => diagnostic.rule,
            'path' => diagnostic.location.relative_path(root),
            'line' => diagnostic.location.line,
            'message' => diagnostic.message
          }
        end
      }

      File.write(path, payload.to_yaml)
    rescue SystemCallError => e
      raise Error, "could not write todo file #{path}: #{e.message}"
    end

    def initialize(ids, root:)
      @ids = ids
      @root = root
    end

    def include?(diagnostic)
      ids.include?(diagnostic.fingerprint(root: root))
    end

    private

    attr_reader :ids, :root
  end
end
