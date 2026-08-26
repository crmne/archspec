# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#cannot_call. Flags calls to the named
    # methods, optionally only bare implicit-+self+ calls.
    class CannotCallRule
      attr_reader :source, :method_names, :receiver

      def initialize(source, methods, receiver: :any)
        unless %i[any none].include?(receiver) || receiver.is_a?(String)
          raise Error, "cannot_call receiver: must be :any, :none or a constant name, got #{receiver.inspect}"
        end

        @source = source.to_sym
        @method_names = Array(methods).flatten.map(&:to_sym)
        @receiver = receiver.is_a?(String) ? receiver.sub(/\A::/, '') : receiver
      end

      def merge_key
        [self.class, source, receiver]
      end

      def merge!(other)
        @method_names |= other.method_names
        self
      end

      def id
        'methods.forbid'
      end

      def evaluate(graph)
        graph.edges.filter_map do |edge|
          next unless edge.type == :calls_named_method
          forbidden = forbidden_name(edge)
          next unless forbidden
          next if receiver == :none && edge.receiver != :none
          next if receiver.is_a?(String) && !receiver_matches?(graph, edge)
          next unless graph.source_components_for(edge).include?(source)
          next if own_method_call?(graph, edge)

          Diagnostic.new(
            rule: id,
            message: "#{source} must not call ##{forbidden}",
            location: edge.location,
            evidence: evidence_for(graph, edge)
          )
        end
      end

      private

      def forbidden_name(edge)
        return edge.to.to_sym if method_names.include?(edge.to.to_sym)
        return edge.resolved_method if edge.resolved_method && method_names.include?(edge.resolved_method)
      end

      def receiver_matches?(graph, edge)
        return false unless edge.resolved_receiver
        return true if edge.resolved_receiver == receiver

        graph.ancestor_names(edge.resolved_receiver, scope: edge.receiver_scope || :instance).first.include?(receiver)
      end

      def evidence_for(graph, edge)
        evidence = "#{graph.edge_source_name(edge)} calls #{edge.to}"
        evidence = "#{evidence} (alias of #{edge.resolved_method})" if edge.resolved_method
        receiver.is_a?(String) ? "#{evidence} on #{edge.resolved_receiver}" : evidence
      end

      # A receiverless call to a method the class itself defines (directly,
      # inherited, or via attr_*/attribute/delegate) is a call to its own API.
      def own_method_call?(graph, edge)
        return false unless edge.receiver == :none && edge.from_constant

        methods, = graph.effective_instance_methods(edge.from_constant)
        methods.include?(edge.to.to_sym)
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#must_implement. Flags classes in the
    # component that do not implement the method, counting inherited and
    # mixed-in methods.
    class MustImplementRule
      attr_reader :source, :method_name, :scope, :arity, :keywords

      def initialize(source, method_name, scope: :instance, arity: nil, keywords: nil)
        ProtocolEvidence.validate_scope!(scope, for_rule: 'must_implement')
        if arity && (!arity.is_a?(Integer) || arity.negative?)
          raise Error, "must_implement arity: must be a non-negative Integer, got #{arity.inspect}"
        end

        @source = source.to_sym
        @method_name = method_name.to_sym
        @scope = scope
        @arity = arity
        @keywords = Array(keywords).compact.map(&:to_sym).to_set
      end

      def merge_key
        [self.class, source, method_name, scope, arity, keywords]
      end

      def id
        'protocol.must_implement'
      end

      def evaluate(graph)
        constants_for(graph).filter_map do |constant|
          definitions, unresolved = graph.effective_method_definitions(constant.name, scope)
          implementations = definitions.select { |definition| definition.name == method_name }
          next if requirement_met?(implementations)

          Diagnostic.new(
            rule: id,
            message: "#{constant.name} must implement #{method_label}#{requirement_clause}",
            location: constant.location,
            evidence: evidence_for(constant, definitions, implementations, unresolved),
            confidence: unresolved.empty? && signature_known?(implementations) ? :high : :medium
          )
        end
      end

      private

      def constants_for(graph)
        ProtocolEvidence.constants_for(graph, source)
      end

      def requirement_met?(implementations)
        return false if implementations.empty?
        return true unless signature_required?

        implementations.any? do |definition|
          definition.signatures.any? do |signature|
            (arity.nil? || signature.accepts_arity?(arity)) && signature.accepts_keywords?(keywords)
          end
        end
      end

      def signature_required?
        !arity.nil? || keywords.any?
      end

      def signature_known?(implementations)
        !signature_required? || implementations.any? { |definition| definition.signatures.any? }
      end

      def method_label
        "#{scope == :class ? '.' : '#'}#{method_name}"
      end

      def requirement_clause
        requirements = []
        requirements << "#{arity} positional #{arity == 1 ? 'argument' : 'arguments'}" if arity
        requirements << "keywords #{keywords.map { |name| "#{name}:" }.sort.join(', ')}" if keywords.any?
        requirements.empty? ? '' : " accepting #{requirements.join(' and ')}"
      end

      def evidence_for(constant, definitions, implementations, unresolved)
        if implementations.empty?
          return ProtocolEvidence.for(constant, definitions.map(&:name).to_set, unresolved, scope: scope)
        end

        signatures = implementations.flat_map(&:signatures)
        detail =
          if signatures.empty?
            'has no recorded signature'
          else
            "accepts #{signatures.map(&:describe).uniq.join(' or ')}"
          end
        evidence = "#{constant.name} #{method_label} #{detail}"
        return evidence if unresolved.empty?

        "#{evidence}; unresolved ancestors: #{unresolved.to_a.sort.join(', ')}"
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#must_implement_one_of. Flags classes
    # that implement none of the named methods.
    class MustImplementOneOfRule
      attr_reader :source, :method_names, :scope

      def initialize(source, method_names, scope: :instance)
        ProtocolEvidence.validate_scope!(scope, for_rule: 'must_implement_one_of')
        @source = source.to_sym
        names = Array(method_names).flatten.compact
        raise Error, 'must_implement_one_of requires at least one method' if names.empty?

        @method_names = names.map(&:to_sym)
        @scope = scope
      end

      def merge_key
        [self.class, source, scope]
      end

      def merge!(other)
        @method_names |= other.method_names
        self
      end

      def id
        'protocol.must_implement_one_of'
      end

      def evaluate(graph)
        constants_for(graph).filter_map do |constant|
          methods, unresolved =
            if scope == :class
              graph.effective_class_methods(constant.name)
            else
              graph.effective_instance_methods(constant.name)
            end
          next if method_names.any? { |method_name| methods.include?(method_name) }

          sigil = scope == :class ? '.' : '#'
          choices = method_names.map { |name| "#{sigil}#{name}" }.join(', ')
          Diagnostic.new(
            rule: id,
            message: "#{constant.name} must implement one of #{choices}",
            location: constant.location,
            evidence: ProtocolEvidence.for(constant, methods, unresolved, scope: scope),
            confidence: unresolved.empty? ? :high : :medium
          )
        end
      end

      private

      def constants_for(graph)
        ProtocolEvidence.constants_for(graph, source)
      end
    end

    # Builds the shared "methods: ..." evidence string for the protocol rules
    # and resolves the classes in a component. Internal helper.
    module ProtocolEvidence
      module_function

      VALID_SCOPES = %i[instance class].freeze

      def validate_scope!(scope, for_rule:)
        return if VALID_SCOPES.include?(scope)

        raise Error, "#{for_rule} scope: must be :instance or :class, got #{scope.inspect}"
      end

      def constants_for(graph, source)
        component = graph.components[source]
        return [] unless component

        graph.constants_for_component(source).select(&:class?).uniq(&:name)
      end

      def for(constant, methods, unresolved, scope: :instance)
        label = scope == :class ? 'class methods' : 'methods'
        evidence = "#{constant.name} #{label}: #{methods.empty? ? '(none)' : methods.to_a.sort.join(', ')}"
        return evidence if unresolved.empty?

        "#{evidence}; unresolved ancestors: #{unresolved.to_a.sort.join(', ')}"
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#cannot_define. Flags method
    # definitions in the component matching the named methods.
    class CannotDefineMethodRule
      attr_reader :source, :method_names

      def initialize(source, methods)
        @source = source.to_sym
        @method_names = Array(methods).flatten.map(&:to_sym)
      end

      def merge_key
        [self.class, source]
      end

      def merge!(other)
        @method_names |= other.method_names
        self
      end

      def id
        'methods.define_forbid'
      end

      def evaluate(graph)
        graph.method_definitions_for_component(source).filter_map do |method_definition|
          next unless method_names.include?(method_definition.name)

          Diagnostic.new(
            rule: id,
            message: "#{source} must not define ##{method_definition.name}",
            location: method_definition.location,
            evidence: "#{method_definition.owner} defines #{method_definition.scope} method #{method_definition.name}"
          )
        end
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#cannot_instantiate_and_invoke. Flags
    # the one-shot <tt>Thing.new(...).call</tt> pattern.
    class CannotInstantiateAndInvokeRule
      attr_reader :source

      def initialize(source)
        @source = source.to_sym
      end

      def merge_key
        [self.class, source]
      end

      def id
        'objects.instantiate_and_invoke_forbid'
      end

      def evaluate(graph)
        graph.edges.filter_map do |edge|
          next unless edge.type == :instantiates_and_invokes
          next unless graph.source_components_for(edge).include?(source)

          Diagnostic.new(
            rule: id,
            message: "#{source} must not instantiate and immediately invoke #{edge.to}",
            location: edge.location,
            evidence: "#{graph.edge_source_name(edge)} uses #{edge.to}"
          )
        end
      end
    end
  end
end
