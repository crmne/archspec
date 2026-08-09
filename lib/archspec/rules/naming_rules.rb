# frozen_string_literal: true

require 'set'

module ArchSpec
  module Rules
    # Backs the +methods.matching(...)+ DSL. One rule pairs a selector (which
    # methods it judges) with a constraint (what must hold of them). It judges a
    # component's defined, public methods in the requested scope, or every such
    # method in the project when +source+ is nil. Every finding is name-based and
    # exact, so confidence is always +:high+.
    class NamingRule
      attr_reader :source, :selector, :scope, :except

      def initialize(source:, selector:, constraint:, scope: :instance, except: [])
        @source = source&.to_sym
        @selector = selector
        @constraint = constraint
        @scope = scope
        @except = Array(except).flatten.map(&:to_sym).to_set
      end

      def id
        @constraint.id
      end

      def evaluate(graph)
        selected = candidate_methods(graph).filter_map do |definition|
          next if except.include?(definition.name)

          match = selector.match(definition)
          [definition, match] if match
        end

        @constraint.diagnostics(selected, self, graph)
      end

      private

      def candidate_methods(graph)
        definitions = source ? graph.method_definitions_for_component(source) : graph.method_definitions
        definitions.select { |definition| definition.scope == scope && definition.visibility == :public }
      end
    end

    # The selectors and constraints the naming DSL composes, plus the builder the
    # DSL returns.
    module Naming
      # Selects methods whose name matches a regex. A named capture in the regex
      # (such as <tt>(?<base>.+)</tt>) is exposed to the +requires+ constraint.
      class NameSelector
        attr_reader :regex

        def initialize(regex)
          @regex = regex
        end

        def match(definition)
          regex.match(definition.name.to_s)
        end

        def describe
          "matches #{regex.inspect}"
        end
      end

      # Forbids any selected method from existing. Rule id +naming.forbidden+.
      class Forbidden
        def initialize(because: nil)
          @because = because
        end

        def id
          'naming.forbidden'
        end

        def diagnostics(selected, rule, _graph)
          selected.map do |definition, _match|
            Diagnostic.new(
              rule: id,
              message: message_for(definition),
              location: definition.location,
              evidence: "#{definition.owner} defines #{definition.scope} method #{definition.name} (#{rule.selector.describe})"
            )
          end
        end

        private

        def message_for(definition)
          base = "#{definition.owner} must not define ##{definition.name}"
          @because ? "#{base}: #{@because}" : base
        end
      end

      # Requires each selected method to have a sibling named by a template, in
      # the same component or another (+on:+), at a given scope. The template
      # interpolates the selector's named captures, as in
      # <tt>requires("without_%{base}")</tt>. Rule id +naming.requires+.
      class Requires
        def initialize(template, on: nil, scope: :instance, because: nil)
          @template = template
          @on = on
          @target_scope = scope
          @because = because
        end

        def id
          'naming.requires'
        end

        def diagnostics(selected, rule, graph)
          target = @on || rule.source
          existing = existing_names(graph, target)

          selected.filter_map do |definition, match|
            sibling = expand(match)
            next if sibling.nil? || existing.include?(sibling.to_sym)

            Diagnostic.new(
              rule: id,
              message: message_for(definition, sibling, target, rule),
              location: definition.location,
              evidence: "#{definition.owner} defines ##{definition.name}, expected ##{sibling}"
            )
          end
        end

        private

        def existing_names(graph, target)
          definitions = target ? graph.method_definitions_for_component(target) : graph.method_definitions
          definitions.select { |definition| definition.scope == @target_scope }.map(&:name).to_set
        end

        def expand(match)
          @template % captures(match)
        rescue KeyError, ArgumentError
          nil
        end

        def captures(match)
          match.is_a?(MatchData) ? match.named_captures.transform_keys(&:to_sym) : {}
        end

        def message_for(definition, sibling, target, rule)
          clause =
            if target && target != rule.source
              "#{target} to define ##{sibling}"
            else
              "a matching ##{sibling}"
            end
          base = "#{definition.owner}##{definition.name} requires #{clause}"
          @because ? "#{base}: #{@because}" : base
        end
      end

      # Returned by ArchSpec::DSL::ComponentProxy#methods. Starts a selector.
      class Builder
        def initialize(component, scope: :instance)
          @component = component
          @scope = scope
        end

        def matching(regex)
          Selected.new(@component, NameSelector.new(regex), @scope)
        end
      end

      # A chosen selector, waiting for a constraint. Each constraint method builds
      # a NamingRule, attaches it, and returns the component proxy so rules chain.
      class Selected
        def initialize(component, selector, scope)
          @component = component
          @selector = selector
          @scope = scope
        end

        def forbidden(except: [], because: nil)
          add(Forbidden.new(because: because), except)
        end

        def requires(template, on: nil, scope: :instance, except: [], because: nil)
          add(Requires.new(template, on: component_name(on), scope: scope, because: because), except)
        end

        private

        def add(constraint, except)
          rule = NamingRule.new(
            source: @component.name,
            selector: @selector,
            constraint: constraint,
            scope: @scope,
            except: except
          )
          @component.definition.add_rule(rule)
          @component
        end

        def component_name(target)
          return if target.nil?

          target.respond_to?(:name) ? target.name : target.to_sym
        end
      end
    end
  end
end
