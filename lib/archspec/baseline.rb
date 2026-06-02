require "set"
require "yaml"

module ArchSpec
  class Baseline
    def self.empty(root: nil)
      new(Set.new, root: root)
    end

    def self.load(path, root:)
      return empty(root: root) unless path && File.exist?(path)

      document = YAML.safe_load_file(path, permitted_classes: [], aliases: false) || {}
      ids = Array(document["violations"]).filter_map do |entry|
        entry.is_a?(Hash) ? entry["id"] : entry
      end

      new(ids.to_set, root: root)
    end

    def self.write(path, diagnostics, root:)
      payload = {
        "violations" => diagnostics.map do |diagnostic|
          {
            "id" => diagnostic.fingerprint(root: root),
            "rule" => diagnostic.rule,
            "path" => diagnostic.location.relative_path(root),
            "line" => diagnostic.location.line,
            "message" => diagnostic.message
          }
        end
      }

      File.write(path, payload.to_yaml)
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
