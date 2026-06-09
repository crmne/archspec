# frozen_string_literal: true

module ArchSpec
  module Rules
    class DependencyRule
      attr_reader :source, :targets

      def initialize(source, targets)
        @source = source.to_sym
        @targets = Array(targets).flatten.map(&:to_sym).to_set
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
        graph.dependency_edges.select { |edge| graph.component_names_for_path(edge.from_path).include?(source) }
      end

      def target_components(graph, edge)
        graph.target_components_for(edge)
      end

      def edge_target(edge)
        edge.to
      end
    end

    class AllowDependenciesRule < DependencyRule
      def id
        'dependencies.allow'
      end

      def evaluate(graph)
        relevant_edges(graph).flat_map do |edge|
          target_components(graph, edge).filter_map do |target|
            next if target == source || targets.include?(target)

            Diagnostic.new(
              rule: id,
              message: "#{source} may not depend on #{target}",
              location: edge.location,
              evidence: "#{edge.from_constant || edge.from_path} #{edge.type} #{edge_target(edge)}"
            )
          end
        end
      end
    end

    class ForbidDependenciesRule < DependencyRule
      def id
        'dependencies.forbid'
      end

      def evaluate(graph)
        relevant_edges(graph).flat_map do |edge|
          forbidden = target_components(graph, edge) & targets

          forbidden.map do |target|
            Diagnostic.new(
              rule: id,
              message: "#{source} must not depend on #{target}",
              location: edge.location,
              evidence: "#{edge.from_constant || edge.from_path} #{edge.type} #{edge_target(edge)}"
            )
          end
        end
      end
    end

    class CannotReferenceConstantsRule
      attr_reader :source, :constants

      def initialize(source, constants)
        @source = source.to_sym
        @constants = Array(constants).flatten.map { |constant| constant.to_s.sub(/\A::/, '') }
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
          next unless graph.component_names_for_path(edge.from_path).include?(source)

          referenced = graph.resolve_constant_reference(edge.to, edge.from_constant)
          next unless constants.any? { |constant| referenced == constant || referenced.start_with?("#{constant}::") }

          Diagnostic.new(
            rule: id,
            message: "#{source} must not reference #{referenced}",
            location: edge.location,
            evidence: "#{edge.from_constant || edge.from_path} #{edge.type} #{edge.to}"
          )
        end
      end
    end
  end
end
