# frozen_string_literal: true

module ArchSpec
  # The checks ArchSpec runs. Each rule responds to +id+ (its stable rule id,
  # used in suppressions and the todo file) and <tt>evaluate(graph)</tt>, which
  # returns ArchSpec::Diagnostic objects. You normally add rules through the
  # ArchSpec::DSL rather than instantiating these directly, but you can pass a
  # custom object of the same shape to ArchSpec::DSL::Context#rule.
  module Rules
    # Base for the allow and forbid dependency rules. Merges repeated
    # declarations for the same source component.
    class DependencyRule
      include Annotated

      attr_reader :source, :targets

      def initialize(source, targets, because: nil, since: nil)
        @source = source.to_sym
        @targets = Array(targets).flatten.map(&:to_sym).to_set
        annotate(because: because, since: since)
      end

      def merge_key
        [self.class, source]
      end

      def merge!(other)
        targets.merge(other.targets)
        self
      end

      private

      def relevant_edges(graph)
        graph.dependency_edges.select { |edge| graph.source_components_for(edge).include?(source) }
      end

      def breach(graph, edge, target, message)
        diagnostic(
          rule: id,
          message: message,
          location: edge.location,
          evidence: graph.edge_evidence(edge),
          confidence: edge.confidence,
          suggested_action: Cut.for_dependency(graph, edge, target)
        )
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#can_only_use. Flags references from the
    # source to any component outside its allowlist.
    class AllowDependenciesRule < DependencyRule
      def id
        'dependencies.allow'
      end

      def evaluate(graph)
        relevant_edges(graph).flat_map do |edge|
          graph.target_components_for(edge).filter_map do |target|
            next if target == source || targets.include?(target)

            breach(graph, edge, target, "#{source} may not depend on #{target}")
          end
        end
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#cannot_use. Flags references from the
    # source to any of the named components.
    class ForbidDependenciesRule < DependencyRule
      def id
        'dependencies.forbid'
      end

      def evaluate(graph)
        relevant_edges(graph).flat_map do |edge|
          forbidden = graph.target_components_for(edge) & targets

          forbidden.map do |target|
            breach(graph, edge, target, "#{source} must not depend on #{target}")
          end
        end
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#can_only_be_used_by. The inverse of an
    # allowlist: flags references to the component from any component that is not
    # an approved consumer. Use it to protect a shared kernel.
    class AllowedConsumersRule
      include Annotated

      attr_reader :source, :consumers

      def initialize(source, consumers, because: nil, since: nil)
        @source = source.to_sym
        @consumers = Array(consumers).flatten.map(&:to_sym).to_set
        annotate(because: because, since: since)
      end

      def merge_key
        [self.class, source]
      end

      def merge!(other)
        consumers.merge(other.consumers)
        self
      end

      def id
        'dependencies.consumers'
      end

      def evaluate(graph)
        graph.dependency_edges.flat_map do |edge|
          next [] unless graph.target_components_for(edge).include?(source)

          offenders = graph.source_components_for(edge).reject do |component|
            component == source || consumers.include?(component)
          end

          offenders.map do |offender|
            diagnostic(
              rule: id,
              message: message_for(offender),
              location: edge.location,
              evidence: graph.edge_evidence(edge),
              confidence: edge.confidence,
              suggested_action: Cut.for_dependency(graph, edge, source)
            )
          end
        end
      end

      private

      def message_for(offender)
        return "#{source} may not be used by #{offender}" if consumers.empty?

        "#{source} may only be used by #{consumers.to_a.sort.join(', ')}, not #{offender}"
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#cannot_reference_constants. Flags
    # references to the named constants or anything nested under them.
    class CannotReferenceConstantsRule
      include Annotated

      attr_reader :source, :constants

      def initialize(source, constants, because: nil, since: nil)
        @source = source.to_sym
        @constants = Array(constants).flatten.map { |constant| constant.to_s.sub(/\A::/, '') }
        annotate(because: because, since: since)
      end

      def merge_key
        [self.class, source]
      end

      def merge!(other)
        @constants |= other.constants
        self
      end

      def id
        'constants.forbid'
      end

      def evaluate(graph)
        graph.dependency_edges.filter_map do |edge|
          next unless graph.source_components_for(edge).include?(source)

          referenced = graph.resolve_edge_constant(edge)
          chain = graph.alias_chain(referenced)
          matched = chain.find do |name|
            constants.any? { |constant| name == constant || name.start_with?("#{constant}::") }
          end
          next unless matched

          evidence = graph.edge_evidence(edge)
          evidence += " (#{referenced} is an alias of #{matched})" if matched != referenced
          diagnostic(
            rule: id,
            message: "#{source} must not reference #{referenced}",
            location: edge.location,
            evidence: evidence,
            confidence: edge.confidence
          )
        end
      end
    end
  end
end
