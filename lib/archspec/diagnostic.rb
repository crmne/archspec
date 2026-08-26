# frozen_string_literal: true

require 'digest'

module ArchSpec
  # One reported violation: the rule id, a message, the source location, the
  # evidence ArchSpec found, and a confidence. Formatters and the todo file read
  # these. Its #fingerprint is the stable id used to match todo entries and
  # suppress specific findings.
  class Diagnostic
    attr_reader :rule, :message, :location, :evidence, :confidence, :reason

    def initialize(rule:, message:, location:, evidence:, confidence: :high, reason: nil)
      @rule = rule
      @message = message
      @location = location
      @evidence = evidence
      @confidence = confidence
      @reason = reason
    end

    def with_reason(reason)
      return self unless reason

      self.class.new(
        rule: rule,
        message: message,
        location: location,
        evidence: evidence,
        confidence: confidence,
        reason: reason
      )
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
      hash = {
        id: fingerprint(root: root),
        rule: rule,
        message: message,
        path: location.relative_path(root),
        line: location.line,
        column: location.column,
        end_line: location.end_line,
        end_column: location.end_column,
        evidence: evidence,
        confidence: confidence.to_s
      }
      hash[:reason] = reason if reason
      hash
    end
  end
end
