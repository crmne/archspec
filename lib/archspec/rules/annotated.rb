# frozen_string_literal: true

require 'date'

module ArchSpec
  module Rules
    # What a rule carries beside its check: the reason it exists, printed with
    # every finding, and the date it holds from, so older breaches are reported
    # rather than failed. Repeated declarations merge; two reasons or two dates
    # that disagree are an error at load time, never a silent choice.
    module Annotated
      attr_reader :reason, :since

      def annotate(because: nil, since: nil)
        @reason = Annotated.reason(because)
        @since = Annotated.date(since)
        self
      end

      def merge_annotations!(other)
        conflict!('reasons', reason, other.reason) if reason && other.reason && reason != other.reason
        conflict!('dates', since, other.since) if since && other.since && since != other.since

        @reason ||= other.reason
        @since ||= other.since
        self
      end

      def self.reason(value)
        text = value.to_s.strip
        text.empty? ? nil : text
      end

      def self.date(value)
        return if value.nil?
        return value if value.is_a?(Date)

        Date.iso8601(value.to_s)
      rescue Date::Error, TypeError
        raise Error, "since: expects a date as YYYY-MM-DD, got #{value.inspect}"
      end

      private

      def diagnostic(**attributes)
        Diagnostic.new(reason: reason, dated: since, **attributes)
      end

      def conflict!(what, mine, theirs)
        raise Error, "#{id} is declared twice with different #{what}: #{mine.inspect} and #{theirs.inspect}"
      end
    end
  end
end
