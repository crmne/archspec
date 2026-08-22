# frozen_string_literal: true

require 'prism'

module ArchSpec
  module Analyzer
    extend self

    def analyze(definition, root:)
      root = File.expand_path(root)
      graph = Graph.new(root)

      ruby_files(definition, root).each do |path|
        result = Prism.parse_file(path)
        graph.add_file(
          path: path,
          parse_errors: parse_errors_for(path, result.errors),
          suppressions: suppressions_for(result.comments)
        )

        SourceVisitor.visit(graph, path, result.value) if result.value
      end

      facts = Facts.load(definition.facts_path, root: root)
      facts = facts.with_file(Associations.facts_file(graph)) if definition.static_associations
      graph.merge_facts(facts)
      graph.assign_components(definition.component_specs.values)
      graph
    end

    private

    def ruby_files(definition, root)
      ignored = ignored_files(definition, root)

      definition.analysis_patterns.flat_map do |pattern|
        Dir.glob(File.absolute_path(pattern, root))
      end.select do |path|
        File.file?(path) && path.end_with?('.rb')
      end.map do |path|
        File.expand_path(path)
      end.uniq.reject do |path|
        ignored.include?(path)
      end.sort
    end

    def ignored_files(definition, root)
      definition.ignore_patterns.flat_map do |pattern|
        Dir.glob(File.absolute_path(pattern, root))
      end.select { |path| File.file?(path) }.map { |path| File.expand_path(path) }.to_set
    end

    def suppressions_for(comments)
      SuppressionParser.parse(comments)
    end

    def parse_errors_for(path, errors)
      errors.map do |error|
        ParseError.new(error.message, SourceLocation.from_prism(path, error.location))
      end
    end

    module SuppressionParser
      extend self

      DISABLE_PATTERN = /\Aarchspec:disable(?:-(next-line|line))?(?:\s+([a-z0-9_.-]+|\*))?(?:\s+--\s*(.+))?\z/i
      ENABLE_PATTERN = /\Aarchspec:enable(?:\s+([a-z0-9_.-]+|\*))?\z/i

      def parse(comments)
        suppressions = []
        active = Hash.new { |hash, key| hash[key] = [] }

        sorted_comments(comments).each do |comment|
          text = comment.slice.sub(/\A#\s?/, '').strip
          line = comment.location.start_line

          if (match = text.match(DISABLE_PATTERN))
            mode, rule, reason = match.captures
            rule = normalize_rule(rule)

            case mode
            when 'line'
              suppressions << Suppression.new(rule, line, line, reason)
            when 'next-line'
              suppressions << Suppression.new(rule, line + 1, line + 1, reason)
            else
              # The block form covers its own line too, so a trailing
              # `# archspec:disable RULE` works like RuboCop's.
              active[rule] << [line, reason]
            end
          elsif (match = text.match(ENABLE_PATTERN))
            rule = normalize_rule(match[1])
            if active[rule].any?
              start_line, reason = active[rule].pop
              suppressions << Suppression.new(rule, start_line, [line - 1, start_line].max, reason)
            end
          end
        end

        active.each do |rule, entries|
          entries.each do |start_line, reason|
            suppressions << Suppression.new(rule, start_line, Float::INFINITY, reason)
          end
        end

        suppressions
      end

      private

      def sorted_comments(comments)
        comments.sort_by { |comment| [comment.location.start_line, comment.location.start_column] }
      end

      def normalize_rule(rule)
        return nil if rule.nil? || rule == '*'

        rule.downcase
      end
    end

    module SourceVisitor
      extend self

      DYNAMIC_MESSAGES = %i[
        class_eval
        const_get
        const_set
        define_method
        instance_eval
        method_missing
        module_eval
        public_send
        send
      ].freeze

      MIXIN_MESSAGES = {
        include: :includes,
        prepend: :prepends,
        extend: :extends
      }.freeze

      # Macros that define methods from their symbol arguments, mapped to the
      # accessors each one generates.
      GENERATED_METHOD_MACROS = {
        attr_reader: %i[reader],
        attr_writer: %i[writer],
        attr_accessor: %i[reader writer],
        attribute: %i[reader writer],
        delegate: %i[reader],
        alias_attribute: %i[reader writer],
        enum: %i[reader writer],
        store_accessor: %i[reader writer],
        belongs_to: %i[reader writer],
        has_one: %i[reader writer],
        has_many: %i[reader writer],
        has_and_belongs_to_many: %i[reader writer]
      }.freeze

      # These name one method and then take options; the rest name every method
      # they define.
      SINGLE_NAME_MACROS = %i[attribute alias_attribute enum belongs_to has_one has_many
                              has_and_belongs_to_many].freeze

      # Active Record builds these around a singular association, so a bare
      # build_session is the model's own method too.
      SINGULAR_ASSOCIATION_MACROS = %i[belongs_to has_one].freeze
      ASSOCIATION_MACROS = %i[belongs_to has_one has_many has_and_belongs_to_many].freeze
      SINGULAR_ASSOCIATION_HELPERS = ['build_%s', 'create_%s', 'create_%s!', 'reload_%s'].freeze

      def visit(graph, path, node, current_constant: nil, namespace: [], nesting: [], visibility: :public,
                default_scope: :instance)
        return unless node

        case node
        when Prism::ProgramNode, Prism::StatementsNode
          visit_children(graph, path, node, current_constant: current_constant, namespace: namespace, nesting: nesting,
                                            visibility: visibility, default_scope: default_scope)
        when Prism::ClassNode
          visit_class(graph, path, node, current_constant: current_constant, namespace: namespace, nesting: nesting)
        when Prism::ModuleNode
          visit_module(graph, path, node, current_constant: current_constant, namespace: namespace, nesting: nesting)
        when Prism::SingletonClassNode
          visit_singleton_class(graph, path, node, current_constant: current_constant, namespace: namespace,
                                                   nesting: nesting, visibility: visibility,
                                                   default_scope: default_scope)
        when Prism::DefNode
          visit_def(graph, path, node, current_constant: current_constant, namespace: namespace,
                                       nesting: nesting, visibility: visibility, default_scope: default_scope)
        when Prism::CallNode
          visit_call(graph, path, node, current_constant: current_constant, namespace: namespace,
                                        nesting: nesting, visibility: visibility, default_scope: default_scope)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
          visit_constant_assignment(graph, path, node, current_constant: current_constant, namespace: namespace,
                                                       nesting: nesting)
        when Prism::ConstantPathNode, Prism::ConstantReadNode
          add_constant_reference(graph, path, node, current_constant, nesting)
        else
          visit_children(graph, path, node, current_constant: current_constant, namespace: namespace, nesting: nesting,
                                            visibility: visibility, default_scope: default_scope)
        end
      end

      private

      def visit_class(graph, path, node, current_constant:, namespace:, nesting:)
        name = qualified_constant_name(node.constant_path, namespace)
        return visit_children(graph, path, node, current_constant: current_constant, namespace: namespace,
                                                 nesting: nesting) unless name

        constant = graph.add_constant(
          name: name,
          kind: :class,
          path: path,
          location: SourceLocation.from_prism(path, node.location),
          nesting: nesting
        )

        if node.superclass
          superclass = constant_reference_name(node.superclass) if constant_node?(node.superclass)

          if superclass
            constant.superclass = superclass
            graph.add_edge(
              type: :inherits_from,
              from_path: path,
              from_constant: constant.name,
              to: superclass,
              location: SourceLocation.from_prism(path, node.superclass.location),
              lexical_nesting: nesting
            )
          else
            # Dynamic superclass (Struct.new, DelegateClass(...)): no
            # inherits_from edge, but constants inside still count as
            # references, and ancestry stays marked unresolved.
            constant.superclass = node.superclass.slice
            visit(graph, path, node.superclass, current_constant: constant.name, namespace: namespace,
                                                nesting: nesting)
          end
        end

        visit_constant_body(graph, path, constant, node.body, constant.name.split('::'),
                            nesting: [constant.name] + nesting)
      end

      def visit_module(graph, path, node, current_constant:, namespace:, nesting:)
        name = qualified_constant_name(node.constant_path, namespace)
        return visit_children(graph, path, node, current_constant: current_constant, namespace: namespace,
                                                 nesting: nesting) unless name

        constant = graph.add_constant(
          name: name,
          kind: :module,
          path: path,
          location: SourceLocation.from_prism(path, node.location),
          nesting: nesting
        )

        visit_constant_body(graph, path, constant, node.body, constant.name.split('::'),
                            nesting: [constant.name] + nesting)
      end

      # +CONST = value+ defines a constant just like the class and module
      # keywords do. Assigning +Class.new+, +Struct.new+, or +Data.define+
      # makes a class whose block is its body; +Module.new+ makes a module;
      # any other value is a plain +:constant+.
      def visit_constant_assignment(graph, path, node, current_constant:, namespace:, nesting:)
        name = assigned_constant_name(node, namespace)
        unless name
          return visit(graph, path, node.value, current_constant: current_constant, namespace: namespace,
                                                nesting: nesting)
        end

        constant = graph.add_constant(
          name: name,
          kind: builder_kind(node.value) || :constant,
          path: path,
          location: SourceLocation.from_prism(path, node.location),
          nesting: nesting
        )

        # Defining Billing::MAX_RETRIES from another file still depends on Billing.
        if node.is_a?(Prism::ConstantPathWriteNode) && node.target.parent
          visit(graph, path, node.target.parent, current_constant: constant.name, namespace: namespace,
                                                 nesting: nesting)
        end

        if constant.class? || constant.module?
          visit_class_builder(graph, path, constant, node.value, nesting)
        else
          visit(graph, path, node.value, current_constant: constant.name, namespace: namespace, nesting: nesting)
        end
      end

      def assigned_constant_name(node, namespace)
        return qualified_constant_name(node.target, namespace) if node.is_a?(Prism::ConstantPathWriteNode)

        namespace.empty? ? node.name.to_s : "#{namespace.join('::')}::#{node.name}"
      end

      BUILDER_KINDS = {
        %w[Class new] => :class,
        %w[Struct new] => :class,
        %w[Data define] => :class,
        %w[Module new] => :module
      }.freeze

      def builder_kind(value)
        return unless value.is_a?(Prism::CallNode) && constant_node?(value.receiver)

        receiver = constant_reference_name(value.receiver)&.sub(/\A::/, '')
        BUILDER_KINDS[[receiver, value.message]]
      end

      def visit_class_builder(graph, path, constant, value, nesting)
        visit_builder_superclass(graph, path, constant, value, nesting) if constant.class?

        block = value.block
        return unless block.is_a?(Prism::BlockNode) && block.body

        visit_constant_body(graph, path, constant, block.body, constant.name.split('::'),
                            nesting: [constant.name] + nesting)
      end

      # +Class.new(Base)+ inherits from Base like the class keyword would.
      # Struct and Data members generate methods we cannot see, so their
      # ancestry stays marked unresolved, as with a dynamic superclass.
      def visit_builder_superclass(graph, path, constant, value, nesting)
        argument = value.arguments&.arguments&.first
        superclass = constant_reference_name(argument) if argument && constant_node?(argument)

        if superclass
          constant.superclass = superclass
          graph.add_edge(
            type: :inherits_from,
            from_path: path,
            from_constant: constant.name,
            to: superclass,
            location: SourceLocation.from_prism(path, argument.location),
            lexical_nesting: nesting
          )
        elsif constant_reference_name(value.receiver)&.sub(/\A::/, '') != 'Class'
          constant.superclass = "#{constant_reference_name(value.receiver)}.#{value.message}"
        end
      end

      # A +class << self+ (or +class << SomeConstant+) block defines methods on a
      # constant's singleton, so they are class methods, and +private+ inside it
      # applies to them. Walk the body with +default_scope: :class+ against the
      # target constant. An unknown target (+class << variable+) still has its
      # body visited for edges, but no methods are attributed.
      def visit_singleton_class(graph, path, node, current_constant:, namespace:, nesting:, visibility:, default_scope:)
        target = singleton_target(node.expression, current_constant)
        constant = target && graph.constants_named(target).find { |candidate| candidate.path == path }

        if constant
          visit_constant_body(graph, path, constant, node.body, namespace, nesting: nesting, default_scope: :class)
        else
          visit_children(graph, path, node, current_constant: nil, namespace: namespace,
                                            nesting: nesting, visibility: visibility, default_scope: :class)
        end
      end

      def singleton_target(expression, current_constant)
        return current_constant if expression.is_a?(Prism::SelfNode)

        constant_reference_name(expression) if constant_node?(expression)
      end

      # Walks a class or module body in source order, tracking method visibility
      # so +private+/+protected+ and their inline and symbol-list forms mark the
      # methods they cover. +default_scope+ is +:class+ inside a singleton class,
      # so bare +def+s there are class methods. Every statement is still handed to
      # +visit+, so all other facts (calls, references, mixins) are recorded
      # exactly as before.
      def visit_constant_body(graph, path, constant, body, namespace, nesting:, default_scope: :instance)
        return unless body

        unless body.is_a?(Prism::StatementsNode)
          return visit(graph, path, body, current_constant: constant.name, namespace: namespace, nesting: nesting,
                                          default_scope: default_scope)
        end

        visibility = :public
        body.body.each do |statement|
          if (modifier = visibility_modifier(statement))
            visibility = apply_visibility_modifier(graph, path, constant, statement, namespace, visibility, modifier,
                                                   default_scope, nesting)
          else
            visit(graph, path, statement, current_constant: constant.name, namespace: namespace,
                                          nesting: nesting, visibility: visibility, default_scope: default_scope)
          end
        end
      end

      def visit_def(graph, path, node, current_constant:, namespace:, nesting:, visibility: :public,
                    default_scope: :instance)
        owner = method_definition_owner(graph, node, current_constant, nesting)
        if owner && (constant = graph.constants_named(owner).find do |candidate|
          candidate.path == path
        end)
          location = SourceLocation.from_prism(path, node.location)
          if node.receiver || default_scope == :class
            constant.add_class_method(node.name, location: location, visibility: visibility)
          else
            constant.add_instance_method(node.name, location: location, visibility: visibility)
          end
        end

        if node.name == :method_missing
          graph.add_edge(
            type: :dynamic_feature,
            from_path: path,
            from_constant: current_constant,
            to: 'method_missing',
            location: SourceLocation.from_prism(path, node.location),
            confidence: :unknown_due_to_dynamic_feature
          )
        end

        visit_children(graph, path, node, current_constant: current_constant, namespace: namespace, nesting: nesting)
      end

      def method_definition_owner(graph, node, current_constant, nesting)
        return current_constant unless node.receiver
        return current_constant if node.receiver.is_a?(Prism::SelfNode)
        return unless constant_node?(node.receiver)

        name = constant_reference_name(node.receiver)
        graph.resolve_constant_reference(name, current_constant, lexical_nesting: nesting) if name
      end

      def visit_call(graph, path, node, current_constant:, namespace:, nesting:, visibility: :public,
                     default_scope: :instance)
        unless node.message
          return visit_children(graph, path, node, current_constant: current_constant, namespace: namespace,
                                                   nesting: nesting, visibility: visibility,
                                                   default_scope: default_scope)
        end

        message = node.message.to_sym
        location = SourceLocation.from_prism(path, node.location)

        if (one_shot = instantiates_and_invokes(node))
          graph.add_edge(
            type: :instantiates_and_invokes,
            from_path: path,
            from_constant: current_constant,
            to: one_shot,
            location: location
          )
        end

        if (required = literal_require_argument(node))
          graph.add_edge(
            type: message == :require_relative ? :requires_relative : :requires,
            from_path: path,
            from_constant: current_constant,
            to: required,
            location: location
          )
        end

        record_generated_methods(graph, path, node, message, current_constant, location, visibility, default_scope)
        record_association(graph, path, node, message, current_constant, location, nesting)
        record_abstract_class(graph, path, node, message, current_constant)

        if (edge_type = MIXIN_MESSAGES[message])
          constant_arguments(node).each do |constant_name|
            if current_constant && (constant = graph.constants_named(current_constant).find do |candidate|
              candidate.path == path
            end)
              constant.add_mixin(message, constant_name)
            end

            graph.add_edge(
              type: edge_type,
              from_path: path,
              from_constant: current_constant,
              to: constant_name,
              location: location,
              lexical_nesting: nesting
            )
          end
        end

        graph.add_edge(
          type: :calls_named_method,
          from_path: path,
          from_constant: current_constant,
          to: message,
          location: location,
          receiver: receiver_kind(node)
        )

        if DYNAMIC_MESSAGES.include?(message)
          graph.add_edge(
            type: :dynamic_feature,
            from_path: path,
            from_constant: current_constant,
            to: message,
            location: location,
            confidence: :unknown_due_to_dynamic_feature
          )
        end

        visit_children(graph, path, node, current_constant: current_constant, namespace: namespace, nesting: nesting,
                                          visibility: visibility, default_scope: default_scope)
      end

      def add_constant_reference(graph, path, node, current_constant, nesting)
        name = constant_reference_name(node)
        return unless name

        graph.add_edge(
          type: :references_constant,
          from_path: path,
          from_constant: current_constant,
          to: name,
          location: SourceLocation.from_prism(path, node.location),
          lexical_nesting: nesting
        )
      end

      def visit_children(graph, path, node, current_constant:, namespace:, nesting:, visibility: :public,
                         default_scope: :instance)
        node.child_nodes.compact.each do |child|
          visit(graph, path, child, current_constant: current_constant, namespace: namespace,
                                    nesting: nesting, visibility: visibility, default_scope: default_scope)
        end
      end

      # Maps a visibility call to [visibility, forced_scope]. A nil forced_scope
      # means the call follows the context (instance methods in a class body,
      # class methods inside +class << self+); +*_class_method+ always targets
      # class methods.
      VISIBILITY_MODIFIERS = {
        private: [:private, nil],
        protected: [:protected, nil],
        public: [:public, nil],
        private_class_method: [:private, :class],
        public_class_method: [:public, :class]
      }.freeze

      # The [visibility, forced_scope] a bare visibility call sets, or nil when
      # the node is not one. Only receiverless calls count, so +obj.private+ is
      # ignored.
      def visibility_modifier(node)
        return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        VISIBILITY_MODIFIERS[node.message&.to_sym]
      end

      # Applies a visibility call and returns the default visibility for the
      # statements that follow it. A bare +private+ changes that default; the
      # inline (+private def foo+) and symbol-list (+private :foo+) forms mark
      # only the methods they name and leave the default unchanged.
      def apply_visibility_modifier(graph, path, constant, node, namespace, current, spec, default_scope, nesting)
        visibility, forced_scope = spec
        scope = forced_scope || default_scope
        arguments = node.arguments&.arguments || []
        definitions = arguments.select { |argument| argument.is_a?(Prism::DefNode) }
        names = arguments.select { |argument| argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode) }

        if definitions.any?
          visit(graph, path, node, current_constant: constant.name, namespace: namespace,
                                   nesting: nesting, visibility: visibility, default_scope: default_scope)
          current
        elsif names.any?
          names.each { |name| constant.set_visibility(name.unescaped.to_sym, scope, visibility) }
          visit(graph, path, node, current_constant: constant.name, namespace: namespace,
                                   nesting: nesting, visibility: current, default_scope: default_scope)
          current
        elsif arguments.empty? && forced_scope.nil?
          visit(graph, path, node, current_constant: constant.name, namespace: namespace,
                                   nesting: nesting, visibility: visibility, default_scope: default_scope)
          visibility
        else
          visit(graph, path, node, current_constant: constant.name, namespace: namespace,
                                   nesting: nesting, visibility: forced_scope.nil? ? visibility : current,
                                   default_scope: default_scope)
          current
        end
      end

      def literal_require_argument(node)
        return unless %i[require require_relative].include?(node.message.to_sym)
        return if node.receiver

        first_argument = node.arguments&.arguments&.first
        return unless first_argument.is_a?(Prism::StringNode)

        first_argument.unescaped
      end

      def constant_arguments(node)
        node.arguments&.arguments&.filter_map do |argument|
          constant_reference_name(argument) if constant_node?(argument)
        end || []
      end

      # attr_*, Rails attribute, association macros, and unprefixed delegate
      # calls define methods; without them, a class calling its own reader looks
      # like a foreign call.
      def record_generated_methods(graph, path, node, message, current_constant, location, visibility, default_scope)
        return unless current_constant && node.receiver.nil?

        kinds = GENERATED_METHOD_MACROS[message]
        return unless kinds

        constant = graph.constants_named(current_constant).find { |candidate| candidate.path == path }
        return unless constant
        return if message == :delegate && truthy_keyword_argument?(node, :prefix)

        adder = default_scope == :class ? :add_class_method : :add_instance_method
        generated_method_names(constant, node, message).each do |name|
          accessors_for(message, name, kinds).each do |accessor|
            constant.public_send(adder, accessor, location: location, visibility: visibility)
          end
        end
      end

      # Keeps the association as declared, options and all, so a producer can
      # decide later what the macro states and what it leaves to the runtime.
      # A class_name that is not a literal is kept as :dynamic rather than
      # dropped, so it can be counted as a refusal instead of read as absent.
      def record_association(graph, path, node, message, current_constant, location, nesting)
        return unless current_constant && node.receiver.nil? && ASSOCIATION_MACROS.include?(message)

        constant = graph.constants_named(current_constant).find { |candidate| candidate.path == path }
        name = symbol_arguments(node).first
        return unless constant && name

        options = keyword_arguments(node)
        constant.add_association(AssociationDeclaration.new(
          constant.name,
          name,
          message,
          literal_or_dynamic(options[:class_name]),
          symbol_value(options[:through]),
          symbol_value(options[:source]),
          options.key?(:source_type),
          truthy_node?(options[:polymorphic]),
          location,
          nesting
        ))
      end

      def record_abstract_class(graph, path, node, message, current_constant)
        return unless current_constant && node.name == :abstract_class= && node.receiver.is_a?(Prism::SelfNode)
        return unless node.arguments&.arguments&.first.is_a?(Prism::TrueNode)

        constant = graph.constants_named(current_constant).find { |candidate| candidate.path == path }
        constant.abstract = true if constant
      end

      def keyword_arguments(node)
        pairs = {}
        node.arguments&.arguments&.each do |argument|
          next unless argument.is_a?(Prism::KeywordHashNode)

          argument.elements.each do |element|
            next unless element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode)

            pairs[element.key.unescaped.to_sym] = element.value
          end
        end
        pairs
      end

      def literal_or_dynamic(value)
        return if value.nil?
        return value.unescaped if value.is_a?(Prism::StringNode) || value.is_a?(Prism::SymbolNode)

        :dynamic
      end

      def symbol_value(value)
        value.unescaped.to_sym if value.is_a?(Prism::SymbolNode) || value.is_a?(Prism::StringNode)
      end

      def truthy_node?(value)
        !value.nil? && !value.is_a?(Prism::FalseNode) && !value.is_a?(Prism::NilNode)
      end

      def accessors_for(message, name, kinds)
        accessors = []
        accessors << name if kinds.include?(:reader)
        accessors << :"#{name}=" if kinds.include?(:writer)
        return accessors unless SINGULAR_ASSOCIATION_MACROS.include?(message)

        accessors + SINGULAR_ASSOCIATION_HELPERS.map { |template| format(template, name).to_sym }
      end

      # Active Record and Active Model take one name followed by options, which
      # may themselves be symbols. CurrentAttributes instead accepts any number
      # of names, so retain every literal name there.
      def generated_method_names(constant, node, message)
        names = symbol_arguments(node)
        return names unless SINGLE_NAME_MACROS.include?(message)
        return names if message == :attribute && current_attributes?(constant)

        names.first(1)
      end

      def current_attributes?(constant)
        constant.superclass.to_s.sub(/\A::/, '') == 'ActiveSupport::CurrentAttributes'
      end

      def symbol_arguments(node)
        node.arguments&.arguments&.filter_map do |argument|
          argument.unescaped.to_sym if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
        end || []
      end

      def truthy_keyword_argument?(node, name)
        truthy_node?(keyword_arguments(node)[name])
      end

      def receiver_kind(node)
        receiver = node.receiver
        return :none if receiver.nil? || receiver.is_a?(Prism::SelfNode)
        return :constant if constant_node?(receiver)

        :other
      end

      def instantiates_and_invokes(node)
        receiver = node.receiver
        return unless receiver.is_a?(Prism::CallNode) && receiver.message&.to_sym == :new

        receiver_node = receiver.receiver
        return unless constant_node?(receiver_node)

        name = constant_reference_name(receiver_node)
        return unless name

        "#{name}##{node.message}"
      end

      # class Users::RolesController inside module Admin defines
      # Admin::Users::RolesController, so compact paths join the namespace too.
      def qualified_constant_name(node, namespace)
        raw = constant_reference_name(node)
        return unless raw

        absolute = node.is_a?(Prism::ConstantPathNode) && node.parent.nil?

        if absolute || namespace.empty?
          raw
        else
          "#{namespace.join('::')}::#{raw}"
        end
      end

      # nil when the path has dynamic parts (self.class::FOO): there is no
      # static name to check against.
      def constant_reference_name(node)
        return unless constant_node?(node)

        node.full_name.to_s
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError,
             Prism::ConstantPathNode::MissingNodesInConstantPathError
        nil
      end

      def constant_node?(node)
        node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      end
    end
  end
end
