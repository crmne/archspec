# frozen_string_literal: true

require 'digest'

module ArchSpec
  # One reported violation: the rule id, a message, the source location, the
  # evidence ArchSpec found, and a confidence. Formatters and the todo file read
  # these. Its #fingerprint is the stable id used to match todo entries and
  # suppress specific findings.
  #
  # A rule that carries a reason, a date, or a suggested action passes them
  # along; none of them enters the fingerprint, so declaring one on a rule a
  # team already runs moves no todo entry.
  class Diagnostic
    attr_reader :rule, :message, :location, :evidence, :confidence, :caveat, :reason, :since, :age,
                :suggested_action

    def initialize(rule:, message:, location:, evidence:, confidence: :high, caveat: nil, reason: nil, since: nil,
                   age: nil, suggested_action: nil)
      @rule = rule
      @message = message
      @location = location
      @evidence = evidence
      @confidence = confidence
      @caveat = caveat
      @reason = reason
      @since = since
      @age = age
      @suggested_action = suggested_action
    end

    # The same finding at medium confidence, with the reason it is less
    # certain. The fingerprint is unchanged, so todo entries still match.
    def doubted(caveat)
      with(confidence: :medium, caveat: caveat)
    end

    # The same finding with its age against the rule's since: date: +:before+
    # when the witness line is older than the date, +:after+ when newer or
    # from that day, +:unknown+ when git could not say.
    def aged(verdict)
      with(age: verdict)
    end

    def predates_rule?
      age == :before
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
        end_line: location.end_line,
        end_column: location.end_column,
        evidence: evidence,
        confidence: confidence.to_s,
        caveat: caveat,
        reason: reason,
        since: since&.iso8601,
        age: age&.to_s,
        suggested_action: suggested_action
      }
    end

    private

    def with(**changes)
      Diagnostic.new(
        rule: rule,
        message: message,
        location: location,
        evidence: evidence,
        confidence: confidence,
        caveat: caveat,
        reason: reason,
        since: since,
        age: age,
        suggested_action: suggested_action,
        **changes
      )
    end
  end
end
