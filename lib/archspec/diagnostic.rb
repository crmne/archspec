# frozen_string_literal: true

require 'digest'

module ArchSpec
  # One reported violation: the rule id, a message, the source location, the
  # evidence ArchSpec found, and a confidence. Formatters and the todo file read
  # these. Its #fingerprint is the stable id used to match todo entries and
  # suppress specific findings.
  class Diagnostic
    attr_reader :rule, :message, :location, :evidence, :confidence

    def initialize(rule:, message:, location:, evidence:, confidence: :high)
      @rule = rule
      @message = message
      @location = location
      @evidence = evidence
      @confidence = confidence
    end

    # Line numbers stay out of the fingerprint so todo entries survive edits
    # that only shift code around.
    def fingerprint(root: nil)
      path = root ? location.relative_path(root) : location.path

      Digest::SHA256.hexdigest(
        [rule, message, path, evidence].join("\0")
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
