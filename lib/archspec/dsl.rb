module ArchSpec
  module DSL
    module Context
      def root(path = nil)
        return root_path unless path

        self.root_path = path.to_s
      end

      def source(*patterns)
        add_source_patterns(patterns)
      end

      def ignore(*patterns)
        add_ignore_patterns(patterns)
      end

      def baseline(path = ".archspec_todo.yml")
        self.baseline_path = path.to_s
      end

      def component(name, in: nil, namespace: nil, constants: nil)
        add_component(
          ComponentSpec.new(name, files: binding.local_variable_get(:in), namespace: namespace, constants: constants)
        )
        ComponentProxy.new(self, name)
      end

      alias layer component
      alias role component

      def preset(name)
        Presets.apply(name, self)
      end

      def no_cycles!(among: nil)
        add_rule(Rules::NoCyclesRule.new(among: among))
      end

      def verify_zeitwerk_names!
        add_rule(Rules::ZeitwerkNamingRule.new)
      end

      def rule(rule)
        add_rule(rule)
      end

      def method_missing(name, ...)
        return ComponentProxy.new(self, name) if component?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        component?(name) || super
      end
    end

    class ComponentProxy
      attr_reader :definition, :name

      def initialize(definition, name)
        @definition = definition
        @name = name.to_sym
      end

      def can_use(*targets)
        add_rule(Rules::AllowDependenciesRule.new(name, targets))
        self
      end

      alias only_depend_on can_use
      alias must_only_depend_on can_use

      def cannot_use(*targets)
        add_rule(Rules::ForbidDependenciesRule.new(name, targets))
        self
      end

      def cannot_call(*methods)
        add_rule(Rules::CannotCallRule.new(name, methods))
        self
      end

      def cannot_define(*methods)
        add_rule(Rules::CannotDefineMethodRule.new(name, methods))
        self
      end

      def cannot_instantiate_and_invoke
        add_rule(Rules::CannotInstantiateAndInvokeRule.new(name))
        self
      end

      def cannot_reference_constants(*constants)
        add_rule(Rules::CannotReferenceConstantsRule.new(name, constants))
        self
      end

      def must_implement(*methods)
        methods.each do |method_name|
          add_rule(Rules::MustImplementRule.new(name, method_name))
        end
        self
      end

      def must_implement_one_of(*methods)
        add_rule(Rules::MustImplementOneOfRule.new(name, methods))
        self
      end

      private

      def add_rule(rule)
        if rule.respond_to?(:merge_key)
          existing = definition.rules.find do |candidate|
            candidate.respond_to?(:merge_key) && candidate.merge_key == rule.merge_key
          end

          return existing.merge!(rule) if existing&.respond_to?(:merge!)
          return existing if existing
        end

        definition.add_rule(rule)
      end
    end
  end
end
