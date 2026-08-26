# frozen_string_literal: true

module ArchSpec
  module Rules
    # Attaches a human reason to any rule without coupling that metadata to the
    # rule's implementation or to diagnostic fingerprints.
    module Reasoned
      attr_reader :archspec_because

      def archspec_because=(reason)
        return unless reason

        reason = reason.to_s.strip
        raise Error, 'because: must not be empty' if reason.empty?
        if archspec_because && archspec_because != reason
          raise Error, "the same rule cannot have two reasons: #{archspec_because.inspect} and #{reason.inspect}"
        end

        @archspec_because = reason
      end

      def evaluate(graph)
        super.map { |diagnostic| diagnostic.with_reason(archspec_because) }
      end
    end

    module_function

    def with_reason(rule, because)
      return rule unless because

      rule.extend(Reasoned) unless rule.is_a?(Reasoned)
      rule.archspec_because = because
      rule
    end
  end
end
