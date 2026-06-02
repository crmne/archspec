module ArchSpec
  module Rules
    class CannotCallRule
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
        "methods.forbid"
      end

      def evaluate(graph)
        graph.edges.filter_map do |edge|
          next unless edge.type == :calls_named_method
          next unless method_names.include?(edge.to.to_sym)
          next unless graph.component_names_for_path(edge.from_path).include?(source)

          Diagnostic.new(
            rule: id,
            message: "#{source} must not call ##{edge.to}",
            location: edge.location,
            evidence: "#{edge.from_constant || edge.from_path} calls #{edge.to}"
          )
        end
      end
    end

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
        "protocol.must_implement"
      end

      def evaluate(graph)
        constants_for(graph).filter_map do |constant|
          next if constant.instance_methods.include?(method_name)

          Diagnostic.new(
            rule: id,
            message: "#{constant.name} must implement ##{method_name}",
            location: constant.location,
            evidence: "#{constant.name} methods: #{constant.instance_methods.to_a.sort.join(", ")}"
          )
        end
      end

      private

      def constants_for(graph)
        graph.components.fetch(source).constants.flat_map { |name| graph.constants_named(name) }.select(&:class?)
      rescue KeyError
        []
      end
    end

    class MustImplementOneOfRule
      attr_reader :source, :method_names

      def initialize(source, method_names)
        @source = source.to_sym
        @method_names = Array(method_names).flatten.map(&:to_sym)
      end

      def merge_key
        [self.class, source]
      end

      def merge!(other)
        @method_names |= other.method_names
        self
      end

      def id
        "protocol.must_implement_one_of"
      end

      def evaluate(graph)
        constants_for(graph).filter_map do |constant|
          next if method_names.any? { |method_name| constant.instance_methods.include?(method_name) }

          Diagnostic.new(
            rule: id,
            message: "#{constant.name} must implement one of #{method_names.map { |name| "##{name}" }.join(", ")}",
            location: constant.location,
            evidence: "#{constant.name} methods: #{constant.instance_methods.to_a.sort.join(", ")}"
          )
        end
      end

      private

      def constants_for(graph)
        graph.components.fetch(source).constants.flat_map { |name| graph.constants_named(name) }.select(&:class?)
      rescue KeyError
        []
      end
    end

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
        "methods.define_forbid"
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
  end
end
