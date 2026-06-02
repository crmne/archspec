require "digest"

module ArchSpec
  class Diagnostic
    attr_reader :rule, :message, :location, :evidence, :confidence

    def initialize(rule:, message:, location:, evidence:, confidence: :high)
      @rule = rule
      @message = message
      @location = location
      @evidence = evidence
      @confidence = confidence
    end

    def fingerprint(root: nil)
      path = root ? location.relative_path(root) : location.path

      Digest::SHA256.hexdigest(
        [rule, message, path, location.line, evidence].join("\0")
      )[0, 24]
    end

    def to_h(root:)
      {
        id: fingerprint(root: root),
        rule: rule,
        message: message,
        path: location.relative_path(root),
        line: location.line,
        column: location.column,
        evidence: evidence,
        confidence: confidence.to_s
      }
    end
  end
end
