# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::ComponentProxy#cannot_call. Flags calls to the named
    # methods, optionally only bare implicit-+self+ calls.
    class CannotCallRule
      attr_reader :source, :method_names, :receiver

      def initialize(source, methods, receiver: :any)
        unless %i[any none].include?(receiver)
          raise Error, "cannot_call receiver: must be :any or :none, got #{receiver.inspect}"
        end

        @source = source.to_sym
        @method_names = Array(methods).flatten.map(&:to_sym)
        @receiver = receiver
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
          next unless method_names.include?(edge.to.to_sym)
          next if receiver == :none && edge.receiver != :none
          next unless graph.source_components_for(edge).include?(source)
          next if own_method_call?(graph, edge)

          Diagnostic.new(
            rule: id,
            message: "#{source} must not call ##{edge.to}",
            location: edge.location,
            evidence: "#{edge.from_constant || edge.from_path} calls #{edge.to}"
          )
        end
      end

      private

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
      attr_reader :source, :method_name

      def initialize(source, method_name)
        @source = source.to_sym
        @method_name = method_name.to_sym
      end

      def merge_key
        [self.class, source, method_name]
      end

      def id
        'protocol.must_implement'
      end

      def evaluate(graph)
        constants_for(graph).filter_map do |constant|
          methods, unresolved = graph.effective_instance_methods(constant.name)
          next if methods.include?(method_name)

          Diagnostic.new(
            rule: id,
            message: "#{constant.name} must implement ##{method_name}",
            location: constant.location,
            evidence: ProtocolEvidence.for(constant, methods, unresolved),
            confidence: unresolved.empty? ? :high : :medium
          )
        end
      end

      private

      def constants_for(graph)
        ProtocolEvidence.constants_for(graph, source)
      end
    end

    # Backs ArchSpec::DSL::ComponentProxy#must_implement_one_of. Flags classes
    # that implement none of the named methods.
    class MustImplementOneOfRule
      attr_reader :source, :method_names

      def initialize(source, method_names)
        @source = source.to_sym
        names = Array(method_names).flatten.compact
        raise Error, 'must_implement_one_of requires at least one method' if names.empty?

        @method_names = names.map(&:to_sym)
      end

      def merge_key
        [self.class, source]
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
          methods, unresolved = graph.effective_instance_methods(constant.name)
          next if method_names.any? { |method_name| methods.include?(method_name) }

          Diagnostic.new(
            rule: id,
            message: "#{constant.name} must implement one of #{method_names.map { |name| "##{name}" }.join(', ')}",
            location: constant.location,
            evidence: ProtocolEvidence.for(constant, methods, unresolved),
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

      def constants_for(graph, source)
        component = graph.components[source]
        return [] unless component

        graph.constants_for_component(source).select(&:class?).uniq(&:name)
      end

      def for(constant, methods, unresolved)
        evidence = "#{constant.name} methods: #{methods.empty? ? '(none)' : methods.to_a.sort.join(', ')}"
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
            evidence: "#{edge.from_constant || edge.from_path} uses #{edge.to}"
          )
        end
      end
    end
  end
end
