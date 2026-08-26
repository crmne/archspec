# frozen_string_literal: true

require 'prism'
require 'set'

module ArchSpec
  module Analyzer
    extend self

    def analyze(definition, root:)
      root = File.expand_path(root)
      graph = Graph.new(root)
      paths = ruby_files(definition, root)
      syntax = SyntaxOverlay.new

      paths.each do |path|
        result = Prism.parse_file(path)
        graph.add_file(
          path: path,
          parse_errors: parse_errors_for(path, result.errors),
          suppressions: suppressions_for(result.comments)
        )
        syntax.scan(path, result.value) if result.value
      end

      method_names = definition.rules.grep(Rules::CannotCallRule).flat_map(&:method_names)
      index = RubydexIndex.new(paths, syntax: syntax, method_names: method_names)
      index.populate(graph)
      syntax.apply(graph, call_resolutions: index.call_resolutions)
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

    # Rubydex supplies the semantic graph. This pass records the few facts
    # whose syntax matters to ArchSpec's rules or that Rubydex does not model.
    class SyntaxOverlay
      Owner = ValueObject.define(:name, :scope)
      ConstantSite = ValueObject.define(:path, :name, :owner, :nesting, :location)
      CallSite = ValueObject.define(:path, :name, :owner, :receiver, :receiver_name, :scope, :nesting, :location)
      CallResolution = ValueObject.define(:receiver, :scope)
      GeneratedMethod = ValueObject.define(:path, :owner, :message, :node, :location, :visibility, :scope)
      MethodOwner = ValueObject.define(:path, :location, :owner)
      DeclarationName = ValueObject.define(:path, :raw, :qualified, :location)
      DeclarationFallback = ValueObject.define(
        :path,
        :name,
        :kind,
        :location,
        :nesting,
        :superclass,
        :superclass_location,
        :dynamic_superclass
      )
      MethodFallback = ValueObject.define(:path, :owner, :name, :scope, :location, :visibility, :signatures)
      MixinFallback = ValueObject.define(:path, :owner, :message, :target, :location, :nesting)

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

      SINGLE_NAME_MACROS = %i[
        attribute
        alias_attribute
        enum
        belongs_to
        has_one
        has_many
        has_and_belongs_to_many
      ].freeze

      SINGULAR_ASSOCIATION_MACROS = %i[belongs_to has_one].freeze
      SINGULAR_ASSOCIATION_HELPERS = ['build_%s', 'create_%s', 'create_%s!', 'reload_%s'].freeze

      BUILDER_KINDS = {
        %w[Class new] => :class,
        %w[Struct new] => :class,
        %w[Data define] => :class,
        %w[Module new] => :module
      }.freeze

      MIXIN_EDGE_TYPES = {
        include: :includes,
        prepend: :prepends,
        extend: :extends
      }.freeze

      VISIBILITY_MODIFIERS = {
        private: [:private, nil],
        protected: [:protected, nil],
        public: [:public, nil],
        private_class_method: [:private, :class],
        public_class_method: [:public, :class]
      }.freeze

      attr_reader :constant_sites, :call_sites

      def initialize
        @constant_sites = []
        @constant_sites_by_path = Hash.new { |hash, key| hash[key] = [] }
        @call_sites = []
        @generated_methods = []
        @declaration_fallbacks = []
        @method_fallbacks = []
        @mixin_fallbacks = []
        @extra_edges = []
        @namespace_flags = Hash.new { |hash, key| hash[key] = [] }
        @declaration_kinds = {}
        @declaration_names = []
        @superclass_overrides = {}
        @superclass_fallbacks = {}
        @method_owner_overrides = []
      end

      def scan(path, node)
        visit(File.expand_path(path), node)
      end

      def apply(graph, call_resolutions: {})
        @declaration_fallbacks.each do |fallback|
          constant = graph.constants_named(fallback.name).find { |candidate| candidate.path == fallback.path }
          unless constant
            constant = graph.add_constant(
              name: fallback.name,
              kind: fallback.kind,
              path: fallback.path,
              location: fallback.location,
              nesting: fallback.nesting
            )
            constant.superclass = fallback.superclass if constant.class?
          end
          add_fallback_ancestry(graph, fallback)
        end
        apply_method_fallbacks(graph)
        apply_mixin_fallbacks(graph)
        @namespace_flags.each do |(name, path), flags|
          graph.set_namespace_only(name, path, flags.all?)
        end
        apply_generated_methods(graph)
        @extra_edges.each { |edge| graph.add_edge(**edge) }
        call_sites.each do |site|
          resolution = call_resolutions[site]
          resolved_method = graph.resolve_method_alias(resolution.receiver, site.name, resolution.scope) if resolution
          graph.add_edge(
            type: :calls_named_method,
            from_path: site.path,
            from_constant: site.owner,
            to: site.name,
            location: site.location,
            receiver: site.receiver,
            resolved_receiver: resolution&.receiver,
            receiver_scope: resolution&.scope,
            resolved_method: resolved_method
          )
        end
      end

      def declaration_kind(name, path)
        @declaration_kinds[[normalize(name), path]]
      end

      def declaration_name(name, path = nil, location = nil)
        normalized = normalize(name)
        return normalized unless path

        candidates = @declaration_names.select do |candidate|
          candidate.path == path &&
            (normalized == candidate.raw || normalized.start_with?("#{candidate.raw}::"))
        end
        candidates.select! { |candidate| contains?(candidate.location, location) } if location
        mapping = candidates.max_by { |candidate| candidate.raw.length }
        mapping ? "#{mapping.qualified}#{normalized.delete_prefix(mapping.raw)}" : normalized
      end

      def superclass_override(name, path)
        @superclass_overrides[[normalize(name), path]]
      end

      def superclass_fallback(name, path)
        @superclass_fallbacks[[normalize(name), path]]
      end

      def constant_name_at(path, location)
        sites = @constant_sites_by_path[path].select { |site| contains?(site.location, location) }
        sites.max_by { |site| site.name.length }&.name
      end

      def method_owner_override(path, location)
        override = @method_owner_overrides.reverse_each.find do |candidate|
          candidate.path == path && contains?(candidate.location, location)
        end
        override&.owner
      end

      def method_owner(name, scope)
        Owner.new(name, scope) if name
      end

      private

      def visit(path, node, current_constant: nil, namespace: [], nesting: [], visibility: :public,
                default_scope: :instance, forced_method_owner: nil)
        return unless node

        case node
        when Prism::ProgramNode, Prism::StatementsNode
          visit_children(path, node, current_constant: current_constant, namespace: namespace, nesting: nesting,
                                     visibility: visibility, default_scope: default_scope,
                                     forced_method_owner: forced_method_owner)
        when Prism::ClassNode
          visit_class(path, node, current_constant: current_constant, namespace: namespace, nesting: nesting)
        when Prism::ModuleNode
          visit_module(path, node, current_constant: current_constant, namespace: namespace, nesting: nesting)
        when Prism::SingletonClassNode
          visit_singleton_class(path, node, current_constant: current_constant, namespace: namespace,
                                            nesting: nesting, visibility: visibility,
                                            forced_method_owner: forced_method_owner)
        when Prism::DefNode
          visit_def(path, node, current_constant: current_constant, namespace: namespace, nesting: nesting,
                                visibility: visibility, default_scope: default_scope,
                                forced_method_owner: forced_method_owner)
        when Prism::CallNode
          visit_call(path, node, current_constant: current_constant, namespace: namespace, nesting: nesting,
                                 visibility: visibility, default_scope: default_scope,
                                 forced_method_owner: forced_method_owner)
        when Prism::ConstantWriteNode, Prism::ConstantPathWriteNode
          visit_constant_assignment(path, node, current_constant: current_constant, namespace: namespace,
                                                nesting: nesting)
        when Prism::ConstantPathNode, Prism::ConstantReadNode
          record_constant_site(path, node, current_constant, nesting)
        else
          visit_children(path, node, current_constant: current_constant, namespace: namespace, nesting: nesting,
                                     visibility: visibility, default_scope: default_scope,
                                     forced_method_owner: forced_method_owner)
        end
      end

      def visit_class(path, node, current_constant:, namespace:, nesting:)
        name = qualified_constant_name(node.constant_path, namespace)
        unless name
          return visit_children(path, node, current_constant: current_constant, namespace: namespace,
                                            nesting: nesting)
        end

        location = SourceLocation.from_prism(path, node.location)
        record_namespace(
          name,
          path,
          node.superclass.nil? && namespace_only_body?(node.body),
          declared_as: constant_reference_name(node.constant_path),
          location: location
        )

        @declaration_fallbacks << DeclarationFallback.new(
          path,
          name,
          :class,
          location,
          nesting,
          class_superclass(node),
          node.superclass && SourceLocation.from_prism(path, node.superclass.location),
          node.superclass && !constant_node?(node.superclass)
        )

        if node.superclass
          if constant_node?(node.superclass)
            @superclass_fallbacks[[normalize(name), path]] = constant_reference_name(node.superclass)
          else
            @superclass_overrides[[normalize(name), path]] = node.superclass.slice
            visit(path, node.superclass, current_constant: name, namespace: namespace, nesting: nesting)
          end
        end

        visit_constant_body(path, name, node.body, name.split('::'), nesting: [name] + nesting)
      end

      def visit_module(path, node, current_constant:, namespace:, nesting:)
        name = qualified_constant_name(node.constant_path, namespace)
        unless name
          return visit_children(path, node, current_constant: current_constant, namespace: namespace,
                                            nesting: nesting)
        end

        location = SourceLocation.from_prism(path, node.location)
        record_namespace(
          name,
          path,
          namespace_only_body?(node.body),
          declared_as: constant_reference_name(node.constant_path),
          location: location
        )
        @declaration_fallbacks << DeclarationFallback.new(
          path,
          name,
          :module,
          location,
          nesting,
          nil,
          nil,
          false
        )
        visit_constant_body(path, name, node.body, name.split('::'), nesting: [name] + nesting)
      end

      def visit_constant_assignment(path, node, current_constant:, namespace:, nesting:)
        name = assigned_constant_name(node, namespace)
        unless name
          return visit(path, node.value, current_constant: current_constant, namespace: namespace, nesting: nesting)
        end

        if node.is_a?(Prism::ConstantPathWriteNode) && node.target.parent
          visit(path, node.target.parent, current_constant: name, namespace: namespace, nesting: nesting)
        end

        kind = builder_kind(node.value)
        superclass = builder_superclass(node.value) if kind == :class
        superclass_argument = node.value.arguments&.arguments&.first if kind == :class
        static_superclass = superclass_argument && constant_node?(superclass_argument)
        location = SourceLocation.from_prism(path, node.location)
        @declaration_fallbacks << DeclarationFallback.new(
          path,
          name,
          kind || :constant,
          location,
          nesting,
          superclass,
          static_superclass && SourceLocation.from_prism(path, superclass_argument.location),
          !!(superclass && !static_superclass)
        )
        unless kind
          return visit(path, node.value, current_constant: name, namespace: namespace, nesting: nesting)
        end

        @declaration_kinds[[normalize(name), path]] = kind
        record_namespace(name, path, false, declared_as: name, location: location)
        if kind == :class
          if static_superclass
            @superclass_fallbacks[[normalize(name), path]] = superclass
          else
            record_builder_superclass(name, path, node.value)
          end
        end

        block = node.value.block
        return unless block.is_a?(Prism::BlockNode) && block.body

        visit_constant_body(
          path,
          name,
          block.body,
          name.split('::'),
          nesting: [name] + nesting,
          forced_method_owner: name
        )
      end

      def visit_singleton_class(path, node, current_constant:, namespace:, nesting:, visibility:,
                                forced_method_owner:)
        target = singleton_target(node.expression, current_constant)
        visit_constant_body(
          path,
          target,
          node.body,
          namespace,
          nesting: nesting,
          default_scope: :class,
          forced_method_owner: forced_method_owner || target
        )
      end

      def visit_constant_body(path, name, body, namespace, nesting:, default_scope: :instance,
                              forced_method_owner: nil)
        return unless body

        unless body.is_a?(Prism::StatementsNode)
          return visit(path, body, current_constant: name, namespace: namespace, nesting: nesting,
                                   default_scope: default_scope, forced_method_owner: forced_method_owner)
        end

        visibility = :public
        body.body.each do |statement|
          if (modifier = visibility_modifier(statement))
            visibility = apply_visibility_modifier(
              path,
              name,
              statement,
              namespace,
              nesting,
              visibility,
              modifier,
              default_scope,
              forced_method_owner
            )
          else
            visit(path, statement, current_constant: name, namespace: namespace, nesting: nesting,
                                   visibility: visibility, default_scope: default_scope,
                                   forced_method_owner: forced_method_owner)
          end
        end
      end

      def visit_def(path, node, current_constant:, namespace:, nesting:, visibility:, default_scope:,
                    forced_method_owner:)
        owner = forced_method_owner || current_constant
        if owner && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          scope = (node.receiver || default_scope == :class) ? :class : :instance
          @method_fallbacks << MethodFallback.new(
            path,
            owner,
            node.name,
            scope,
            SourceLocation.from_prism(path, node.location),
            visibility,
            prism_signatures(node)
          )
        end

        if forced_method_owner && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          scope = (node.receiver || default_scope == :class) ? :class : :instance
          owner = Owner.new(forced_method_owner, scope)
          @method_owner_overrides << MethodOwner.new(
            path,
            SourceLocation.from_prism(path, node.location),
            owner
          )
        end

        if node.name == :method_missing
          @extra_edges << {
            type: :dynamic_feature,
            from_path: path,
            from_constant: forced_method_owner || current_constant,
            to: 'method_missing',
            location: SourceLocation.from_prism(path, node.location),
            confidence: :unknown_due_to_dynamic_feature
          }
        end

        visit_children(path, node, current_constant: forced_method_owner || current_constant,
                                   namespace: namespace, nesting: nesting, default_scope: scope,
                                   forced_method_owner: forced_method_owner)
      end

      def visit_call(path, node, current_constant:, namespace:, nesting:, visibility:, default_scope:,
                     forced_method_owner:)
        unless node.message
          return visit_children(path, node, current_constant: current_constant, namespace: namespace,
                                            nesting: nesting, visibility: visibility,
                                            default_scope: default_scope, forced_method_owner: forced_method_owner)
        end

        message = node.message.to_sym
        location = SourceLocation.from_prism(path, node.location)
        owner = forced_method_owner || current_constant
        @call_sites << CallSite.new(
          path,
          message,
          owner,
          receiver_kind(node),
          constant_reference_name(node.receiver),
          default_scope,
          nesting,
          location
        )

        if (one_shot = instantiates_and_invokes(node))
          @extra_edges << {
            type: :instantiates_and_invokes,
            from_path: path,
            from_constant: owner,
            to: one_shot,
            location: location
          }
        end

        if (required = literal_require_argument(node))
          @extra_edges << {
            type: message == :require_relative ? :requires_relative : :requires,
            from_path: path,
            from_constant: owner,
            to: required,
            location: location
          }
        end

        record_generated_method(path, node, message, owner, location, visibility, default_scope)
        record_mixin_fallback(path, node, message, owner, location, nesting)

        if DYNAMIC_MESSAGES.include?(message)
          @extra_edges << {
            type: :dynamic_feature,
            from_path: path,
            from_constant: owner,
            to: message,
            location: location,
            confidence: :unknown_due_to_dynamic_feature
          }
        end

        visit_children(path, node, current_constant: owner, namespace: namespace, nesting: nesting,
                                   visibility: visibility, default_scope: default_scope,
                                   forced_method_owner: forced_method_owner)
      end

      def record_constant_site(path, node, current_constant, nesting)
        name = constant_reference_name(node)
        return unless name

        site = ConstantSite.new(
          path,
          name,
          current_constant,
          nesting,
          SourceLocation.from_prism(path, node.location)
        )
        @constant_sites << site
        @constant_sites_by_path[path] << site
      end

      def visit_children(path, node, current_constant:, namespace:, nesting:, visibility: :public,
                         default_scope: :instance, forced_method_owner: nil)
        node.child_nodes.compact.each do |child|
          visit(path, child, current_constant: current_constant, namespace: namespace, nesting: nesting,
                             visibility: visibility, default_scope: default_scope,
                             forced_method_owner: forced_method_owner)
        end
      end

      def record_namespace(name, path, namespace_only, declared_as:, location:)
        @namespace_flags[[normalize(name), path]] << namespace_only
        raw = normalize(declared_as)
        return unless raw.include?('::') && raw != normalize(name)

        @declaration_names << DeclarationName.new(path, raw, normalize(name), location)
      end

      def namespace_only_body?(body)
        body.is_a?(Prism::StatementsNode) &&
          !body.body.empty? &&
          body.body.all? { |child| child.is_a?(Prism::ClassNode) || child.is_a?(Prism::ModuleNode) }
      end

      def assigned_constant_name(node, namespace)
        return qualified_constant_name(node.target, namespace) if node.is_a?(Prism::ConstantPathWriteNode)

        namespace.empty? ? node.name.to_s : "#{namespace.join('::')}::#{node.name}"
      end

      def builder_kind(value)
        return unless value.is_a?(Prism::CallNode) && constant_node?(value.receiver)

        receiver = constant_reference_name(value.receiver)&.sub(/\A::/, '')
        BUILDER_KINDS[[receiver, value.message]]
      end

      def class_superclass(node)
        return unless node.superclass
        return constant_reference_name(node.superclass) if constant_node?(node.superclass)

        node.superclass.slice
      end

      def record_builder_superclass(name, path, value)
        argument = value.arguments&.arguments&.first
        return if argument && constant_node?(argument)

        receiver = constant_reference_name(value.receiver)&.sub(/\A::/, '')
        return if receiver == 'Class'

        @superclass_overrides[[normalize(name), path]] = "#{constant_reference_name(value.receiver)}.#{value.message}"
      end

      def builder_superclass(value)
        argument = value.arguments&.arguments&.first
        return constant_reference_name(argument) if argument && constant_node?(argument)

        receiver = constant_reference_name(value.receiver)&.sub(/\A::/, '')
        "#{constant_reference_name(value.receiver)}.#{value.message}" unless receiver == 'Class'
      end

      def singleton_target(expression, current_constant)
        return current_constant if expression.is_a?(Prism::SelfNode)

        constant_reference_name(expression) if constant_node?(expression)
      end

      def visibility_modifier(node)
        return unless node.is_a?(Prism::CallNode) && node.receiver.nil?

        VISIBILITY_MODIFIERS[node.message&.to_sym]
      end

      def apply_visibility_modifier(path, owner, node, namespace, nesting, current, spec, default_scope,
                                    forced_method_owner)
        visibility, forced_scope = spec
        arguments = node.arguments&.arguments || []
        definitions = arguments.select { |argument| argument.is_a?(Prism::DefNode) }
        names = arguments.select { |argument| argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode) }

        if definitions.any?
          visit(path, node, current_constant: owner, namespace: namespace, nesting: nesting,
                            visibility: visibility, default_scope: default_scope,
                            forced_method_owner: forced_method_owner)
          current
        elsif names.any?
          set_fallback_visibility(path, owner, names, forced_scope || default_scope, visibility)
          visit(path, node, current_constant: owner, namespace: namespace, nesting: nesting,
                            visibility: current, default_scope: default_scope,
                            forced_method_owner: forced_method_owner)
          current
        elsif arguments.empty? && forced_scope.nil?
          visit(path, node, current_constant: owner, namespace: namespace, nesting: nesting,
                            visibility: visibility, default_scope: default_scope,
                            forced_method_owner: forced_method_owner)
          visibility
        else
          visit(path, node, current_constant: owner, namespace: namespace, nesting: nesting,
                            visibility: forced_scope.nil? ? visibility : current,
                            default_scope: default_scope, forced_method_owner: forced_method_owner)
          current
        end
      end

      def record_generated_method(path, node, message, owner, location, visibility, scope)
        return unless owner && node.receiver.nil? && GENERATED_METHOD_MACROS.key?(message)

        @generated_methods << GeneratedMethod.new(path, owner, message, node, location, visibility, scope)
      end

      def record_mixin_fallback(path, node, message, owner, location, nesting)
        return unless MIXIN_EDGE_TYPES.key?(message)

        constant_arguments(node).each do |target|
          @mixin_fallbacks << MixinFallback.new(path, owner, message, target, location, nesting)
        end
      end

      def apply_generated_methods(graph)
        @generated_methods.each do |generated|
          constant = graph.constants_named(generated.owner).find { |candidate| candidate.path == generated.path }
          next unless constant
          next if generated.message == :delegate && truthy_keyword_argument?(generated.node, :prefix)

          generated_method_names(constant, generated.node, generated.message).each do |name|
            accessors_for(generated.message, name).each do |accessor|
              scope = generated.scope == :class ? :class : :instance
              next if constant.method_definitions.any? do |definition|
                definition.name == accessor && definition.scope == scope
              end

              adder = scope == :class ? :add_class_method : :add_instance_method
              constant.public_send(
                adder,
                accessor,
                location: generated.location,
                visibility: generated.visibility
              )
            end
          end
        end
      end

      def apply_method_fallbacks(graph)
        @method_fallbacks.each do |fallback|
          constant = graph.constants_named(fallback.owner).find { |candidate| candidate.path == fallback.path }
          next unless constant
          next if constant.method_definitions.any? do |definition|
            definition.name == fallback.name && definition.scope == fallback.scope
          end

          adder = fallback.scope == :class ? :add_class_method : :add_instance_method
          constant.public_send(
            adder,
            fallback.name,
            location: fallback.location,
            visibility: fallback.visibility,
            signatures: fallback.signatures
          )
        end
      end

      def add_fallback_ancestry(graph, fallback)
        return unless fallback.kind == :class && fallback.superclass && !fallback.dynamic_superclass
        return if graph.edges.any? do |edge|
          edge.type == :inherits_from && edge.from_path == fallback.path && edge.from_constant == fallback.name
        end

        graph.add_edge(
          type: :inherits_from,
          from_path: fallback.path,
          from_constant: fallback.name,
          to: fallback.superclass,
          location: fallback.superclass_location || fallback.location,
          lexical_nesting: fallback.nesting
        )
      end

      def apply_mixin_fallbacks(graph)
        @mixin_fallbacks.each do |fallback|
          type = MIXIN_EDGE_TYPES.fetch(fallback.message)
          next if graph.edges.any? do |edge|
            edge.type == type && edge.from_path == fallback.path && edge.from_constant == fallback.owner &&
              edge.to == fallback.target
          end

          constant = graph.constants_named(fallback.owner).find { |candidate| candidate.path == fallback.path }
          constant&.add_mixin(fallback.message, fallback.target)
          graph.add_edge(
            type: type,
            from_path: fallback.path,
            from_constant: fallback.owner,
            to: fallback.target,
            location: fallback.location,
            lexical_nesting: fallback.nesting
          )
        end
      end

      def set_fallback_visibility(path, owner, names, scope, visibility)
        method_names = names.map { |name| name.unescaped.to_sym }
        @method_fallbacks.map! do |fallback|
          if fallback.path == path && fallback.owner == owner && fallback.scope == scope &&
             method_names.include?(fallback.name)
            fallback.with(visibility: visibility)
          else
            fallback
          end
        end
      end

      def accessors_for(message, name)
        kinds = GENERATED_METHOD_MACROS.fetch(message)
        accessors = []
        accessors << name if kinds.include?(:reader)
        accessors << :"#{name}=" if kinds.include?(:writer)
        return accessors unless SINGULAR_ASSOCIATION_MACROS.include?(message)

        accessors + SINGULAR_ASSOCIATION_HELPERS.map { |template| format(template, name).to_sym }
      end

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
        node.arguments&.arguments&.any? do |argument|
          argument.is_a?(Prism::KeywordHashNode) && argument.elements.any? do |element|
            element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
              element.key.unescaped.to_sym == name &&
              !element.value.is_a?(Prism::FalseNode) &&
              !element.value.is_a?(Prism::NilNode)
          end
        end
      end

      def literal_require_argument(node)
        return unless %i[require require_relative].include?(node.message.to_sym)
        return if node.receiver

        first_argument = node.arguments&.arguments&.first
        first_argument.unescaped if first_argument.is_a?(Prism::StringNode)
      end

      def constant_arguments(node)
        node.arguments&.arguments&.filter_map do |argument|
          constant_reference_name(argument) if constant_node?(argument)
        end || []
      end

      def prism_signatures(node)
        parameters = node.parameters
        return [] unless parameters

        keywords = parameters.keywords
        forward = parameters.keyword_rest.is_a?(Prism::ForwardingParameterNode)
        [
          MethodSignature.new(
            parameters.requireds.length + parameters.posts.length,
            parameters.optionals.length,
            !parameters.rest.nil? || forward,
            keywords.grep(Prism::RequiredKeywordParameterNode).map(&:name),
            keywords.grep(Prism::OptionalKeywordParameterNode).map(&:name),
            !parameters.keyword_rest.nil? && !forward,
            !parameters.block.nil? || forward,
            forward
          )
        ]
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
        return unless constant_node?(receiver.receiver)

        name = constant_reference_name(receiver.receiver)
        "#{name}##{node.message}" if name
      end

      def qualified_constant_name(node, namespace)
        raw = constant_reference_name(node)
        return unless raw

        absolute = node.is_a?(Prism::ConstantPathNode) && node.parent.nil?
        absolute || namespace.empty? ? raw : "#{namespace.join('::')}::#{raw}"
      end

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

      def contains?(outer, inner)
        position(outer.line, outer.column) <= position(inner.line, inner.column) &&
          position(outer.end_line, outer.end_column) >= position(inner.end_line, inner.end_column)
      end

      def position(line, column)
        (line << 32) + column
      end

      def normalize(name)
        name.to_s.sub(/\A::/, '')
      end
    end
  end
end
