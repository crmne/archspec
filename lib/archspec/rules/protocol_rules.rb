# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#cannot_call. Flags calls to the named
    # methods, optionally only bare implicit-+self+ calls.
    class CannotCallRule
      include Annotated

      ID = 'methods.forbid'

      attr_reader :source, :method_names, :receiver

      # A receiver given as a constant name matches a call whose recorded
      # receiver resolves to that constant or to one of its descendants; a
      # call on an untyped receiver never matches it.
      def self.named?(receiver)
        receiver.is_a?(String) || receiver.is_a?(Module)
      end

      def initialize(source, methods, receiver: :any, because: nil, since: nil)
        unless %i[any none].include?(receiver) || self.class.named?(receiver)
          raise Error, "cannot_call receiver: must be :any, :none or a constant name, got #{receiver.inspect}"
        end

        @source = source.to_sym
        @method_names = Array(methods).flatten.map(&:to_sym)
        @receiver = self.class.named?(receiver) ? receiver.to_s.sub(/\A::/, '') : receiver
        annotate(because: because, since: since)
      end

      def merge_key
        [self.class, source, receiver]
      end

      def merge!(other)
        @method_names |= other.method_names
        self
      end

      def id
        ID
      end

      def evaluate(graph)
        graph.edges.filter_map do |edge|
          next unless edge.type == :calls_named_method
          next unless method_names.include?(edge.to.to_sym) || aliased?(graph, edge)
          next if receiver == :none && edge.receiver != :none
          next if receiver.is_a?(String) && !on_receiver?(graph, edge)
          next unless graph.source_components_for(edge).include?(source)
          next if own_method_call?(graph, edge)

          diagnostic(
            rule: id,
            message: "#{source} must not call ##{edge.to}",
            location: edge.location,
            evidence: evidence_for(graph, edge)
          )
        end
      end

      private

      def on_receiver?(graph, edge)
        return false unless edge.receiver == :constant && edge.receiver_constant

        resolved = graph.resolve_constant_reference(edge.receiver_constant, edge.from_constant, lexical_nesting: edge.lexical_nesting)
        graph.descends_from?(resolved, receiver)
      end

      def aliased?(graph, edge)
        return false unless edge.receiver_constant

        resolved = graph.resolve_constant_reference(edge.receiver_constant, edge.from_constant, lexical_nesting: edge.lexical_nesting)
        graph.method_alias_targets(resolved, edge.to).any? { |target| method_names.include?(target) }
      end

      def evidence_for(graph, edge)
        evidence = "#{graph.edge_source_name(edge)} calls #{edge.to}"
        evidence += " on #{edge.receiver_constant}" if receiver.is_a?(String)
        evidence
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
      include Annotated

      ID = 'protocol.must_implement'

      attr_reader :source, :method_name, :scope, :arity, :keywords

      def initialize(source, method_name, scope: :instance, arity: nil, keyword: nil, because: nil, since: nil)
        @source = source.to_sym
        @method_name = method_name.to_sym
        @scope = ProtocolEvidence.validate_scope(scope)
        @arity = ProtocolEvidence.validate_arity(arity)
        @keywords = Array(keyword).flatten.compact.map(&:to_sym)
        annotate(because: because, since: since)
      end

      def merge_key
        [self.class, source, method_name, scope]
      end

      def merge!(other)
        @arity ||= other.arity
        @keywords |= other.keywords
        self
      end

      def id
        ID
      end

      def evaluate(graph)
        constants_for(graph).filter_map do |constant|
          methods, unresolved = graph.effective_methods_in_scope(constant.name, scope)
          next shape_diagnostic(graph, constant, unresolved) if methods.include?(method_name)

          diagnostic(
            rule: id,
            message: "#{constant.name} must implement #{ProtocolEvidence.describe(method_name, scope)}",
            location: constant.location,
            evidence: ProtocolEvidence.for(constant, methods, unresolved, scope),
            confidence: unresolved.empty? ? :high : :medium
          )
        end
      end

      private

      # What the implementation takes, checked against the arity and the
      # keywords the protocol asks for. A definition nobody described has no
      # signature, and that is the miss the evidence names; it is never read
      # as conforming.
      def shape_diagnostic(graph, constant, unresolved)
        return nil if arity.nil? && keywords.empty?
        return nil if graph.resolvers.empty?

        definition = graph.definition_in_chain(constant.name, method_name, scope)
        signature = definition&.signature
        problems = ProtocolEvidence.signature_problems(signature, arity, keywords)
        return nil if problems.empty?

        diagnostic(
          rule: id,
          message: "#{constant.name} must implement #{ProtocolEvidence.describe(method_name, scope)} #{ProtocolEvidence.describe_shape(arity, keywords)}",
          location: definition&.location || constant.location,
          evidence: "#{constant.name} #{ProtocolEvidence.describe(method_name, scope)} #{problems.join(', ')}",
          confidence: unresolved.empty? ? :high : :medium
        )
      end

      def constants_for(graph)
        ProtocolEvidence.constants_for(graph, source)
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#cannot_take. Flags public method
    # definitions in the component that take a block, a rest parameter, or a
    # named keyword.
    class CannotTakeRule
      include Annotated

      ID = 'methods.take_forbid'
      SHAPES = %i[block rest].freeze

      attr_reader :source, :shapes, :keywords

      def initialize(source, shapes, keyword: nil, because: nil, since: nil)
        @source = source.to_sym
        @shapes = Array(shapes).flatten.compact.map(&:to_sym)
        unknown = @shapes - SHAPES
        raise Error, "cannot_take takes :block, :rest or keyword:, got #{unknown.first.inspect}" if unknown.any?

        @keywords = Array(keyword).flatten.compact.map(&:to_sym)
        raise Error, 'cannot_take needs a shape or a keyword' if @shapes.empty? && @keywords.empty?

        annotate(because: because, since: since)
      end

      def merge_key
        [self.class, source]
      end

      def merge!(other)
        @shapes |= other.shapes
        @keywords |= other.keywords
        self
      end

      def id
        ID
      end

      def evaluate(graph)
        graph.method_definitions_for_component(source).filter_map do |definition|
          next unless definition.visibility == :public
          next if definition.signature.nil?

          taken = taken_by(definition.signature)
          next if taken.empty?

          diagnostic(
            rule: id,
            message: "#{source} must not take #{taken.join(', ')}",
            location: definition.location,
            evidence: "#{definition.owner}#{ProtocolEvidence.describe(definition.name, definition.scope)} takes #{taken.join(', ')}"
          )
        end
      end

      private

      def taken_by(signature)
        found = []
        found << 'a block' if shapes.include?(:block) && signature.block
        found << 'a rest parameter' if shapes.include?(:rest) && signature.rest
        keywords.each { |keyword| found << "keyword #{keyword}" if signature.keyword?(keyword) }
        found
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#must_implement_one_of. Flags classes
    # that implement none of the named methods.
    class MustImplementOneOfRule
      include Annotated

      attr_reader :source, :method_names, :scope

      def initialize(source, method_names, scope: :instance, because: nil, since: nil)
        @source = source.to_sym
        names = Array(method_names).flatten.compact
        raise Error, 'must_implement_one_of requires at least one method' if names.empty?

        @method_names = names.map(&:to_sym)
        @scope = ProtocolEvidence.validate_scope(scope)
        annotate(because: because, since: since)
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
          methods, unresolved = graph.effective_methods_in_scope(constant.name, scope)
          next if method_names.any? { |method_name| methods.include?(method_name) }

          described = method_names.map { |name| ProtocolEvidence.describe(name, scope) }.join(', ')
          diagnostic(
            rule: id,
            message: "#{constant.name} must implement one of #{described}",
            location: constant.location,
            evidence: ProtocolEvidence.for(constant, methods, unresolved, scope),
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
      VALID_SCOPES = %i[instance class].freeze

      module_function

      def validate_scope(scope)
        return scope if VALID_SCOPES.include?(scope)

        raise Error, "protocol scope: must be :instance or :class, got #{scope.inspect}"
      end

      def validate_arity(arity)
        return nil if arity.nil?
        return arity if arity.is_a?(Integer) && arity >= 0
        return arity if arity.is_a?(Range) && arity.begin.is_a?(Integer)

        raise Error, "protocol arity: must be a count or a range, got #{arity.inspect}"
      end

      def describe_shape(arity, keywords)
        parts = []
        parts << "taking #{arity.is_a?(Range) ? "#{arity.begin} to #{arity.end || 'any'}" : arity} positional" if arity
        parts << "with keyword #{keywords.map { |keyword| "#{keyword}:" }.join(' ')}" if keywords.any?
        parts.join(' ')
      end

      def signature_problems(signature, arity, keywords)
        return ['has no recorded signature'] if signature.nil?

        problems = []
        if arity && !arity_matches?(signature, arity)
          problems << "takes #{signature.required}#{signature.optional.positive? ? " to #{signature.required + signature.optional}" : ''}#{signature.rest ? ' or more' : ''} positional"
        end
        missing = keywords.reject { |keyword| signature.keyword?(keyword) }
        problems << "lacks keyword #{missing.map { |keyword| "#{keyword}:" }.join(' ')}" if missing.any?
        problems
      end

      def arity_matches?(signature, arity)
        wanted = arity.is_a?(Range) ? arity : (arity..arity)
        taken = signature.arity_range
        return taken.begin <= wanted.begin if wanted.end.nil? && taken.end.nil?
        return false if taken.end.nil? && wanted.end
        return taken.begin <= wanted.begin if wanted.end.nil?

        taken.begin <= wanted.begin && taken.end >= wanted.end
      end

      def describe(method_name, scope)
        scope == :class ? ".#{method_name}" : "##{method_name}"
      end

      def constants_for(graph, source)
        component = graph.components[source]
        return [] unless component

        graph.constants_for_component(source).select(&:class?).uniq(&:name)
      end

      def for(constant, methods, unresolved, scope = :instance)
        listed = methods.empty? ? '(none)' : methods.to_a.sort.join(', ')
        label = scope == :class ? 'class methods' : 'methods'
        evidence = "#{constant.name} #{label}: #{listed}"
        return evidence if unresolved.empty?

        "#{evidence}; unresolved ancestors: #{unresolved.to_a.sort.join(', ')}"
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#cannot_define. Flags method
    # definitions in the component matching the named methods.
    class CannotDefineMethodRule
      include Annotated

      attr_reader :source, :method_names

      def initialize(source, methods, because: nil, since: nil)
        @source = source.to_sym
        @method_names = Array(methods).flatten.map(&:to_sym)
        annotate(because: because, since: since)
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

          diagnostic(
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
      include Annotated

      attr_reader :source

      def initialize(source, because: nil, since: nil)
        @source = source.to_sym
        annotate(because: because, since: since)
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

          diagnostic(
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
