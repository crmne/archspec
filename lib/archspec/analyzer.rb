# frozen_string_literal: true

require 'prism'
require 'pathname'

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
          expected_constant: expected_constant_for(path, root, definition.inflections),
          parse_errors: parse_errors_for(path, result.errors),
          suppressions: suppressions_for(result.comments)
        )

        SourceVisitor.visit(graph, path, result.value) if result.value
      end

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

    def expected_constant_for(path, root, inflections = {})
      relative = Pathname(path).relative_path_from(Pathname(root)).to_s
      stem =
        case relative
        when %r{\Aapp/[^/]+/concerns/(.+)\.rb\z}
          Regexp.last_match(1)
        when %r{\Aapp/[^/]+/(.+)\.rb\z}
          Regexp.last_match(1)
        when %r{\Alib/(.+)\.rb\z}
          Regexp.last_match(1)
        when %r{\A(?:packs|engines)/[^/]+/app/[^/]+/concerns/(.+)\.rb\z}
          Regexp.last_match(1)
        when %r{\A(?:packs|engines)/[^/]+/app/[^/]+/(.+)\.rb\z}
          Regexp.last_match(1)
        else
          return nil
        end

      camelize_path(stem, inflections)
    end

    # Rails-style acronyms: inflections apply to whole path segments first,
    # then to each snake_case word (inflect "api" => "API" fixes both api.rb
    # and api_client.rb).
    def camelize_path(path, inflections = {})
      path.split('/').map do |part|
        inflections[part] || part.split('_').map do |word|
          inflections[word] || (word[0] ? word[0].upcase + word[1..] : word)
        end.join
      end.join('::')
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
              active[rule] << [line + 1, reason]
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

      ATTR_MESSAGES = {
        attr_reader: %i[reader],
        attr_writer: %i[writer],
        attr_accessor: %i[reader writer]
      }.freeze

      def visit(graph, path, node, current_constant: nil, namespace: [])
        return unless node

        case node
        when Prism::ProgramNode, Prism::StatementsNode
          visit_children(graph, path, node, current_constant: current_constant, namespace: namespace)
        when Prism::ClassNode
          visit_class(graph, path, node, current_constant: current_constant, namespace: namespace)
        when Prism::ModuleNode
          visit_module(graph, path, node, current_constant: current_constant, namespace: namespace)
        when Prism::DefNode
          visit_def(graph, path, node, current_constant: current_constant, namespace: namespace)
        when Prism::CallNode
          visit_call(graph, path, node, current_constant: current_constant, namespace: namespace)
        when Prism::ConstantPathNode, Prism::ConstantReadNode
          add_constant_reference(graph, path, node, current_constant)
        else
          visit_children(graph, path, node, current_constant: current_constant, namespace: namespace)
        end
      end

      private

      def visit_class(graph, path, node, current_constant:, namespace:)
        name = qualified_constant_name(node.constant_path, namespace)
        constant = graph.add_constant(
          name: name,
          kind: :class,
          path: path,
          location: SourceLocation.from_prism(path, node.location)
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
              location: SourceLocation.from_prism(path, node.superclass.location)
            )
          else
            # Dynamic superclass (Struct.new, DelegateClass(...)): no
            # inherits_from edge, but constants inside still count as
            # references, and ancestry stays marked unresolved.
            constant.superclass = node.superclass.slice
            visit(graph, path, node.superclass, current_constant: constant.name,
                                                namespace: constant.name.split('::'))
          end
        end

        visit(graph, path, node.body, current_constant: constant.name, namespace: constant.name.split('::'))
      end

      def visit_module(graph, path, node, current_constant:, namespace:)
        name = qualified_constant_name(node.constant_path, namespace)
        constant = graph.add_constant(
          name: name,
          kind: :module,
          path: path,
          location: SourceLocation.from_prism(path, node.location)
        )

        visit(graph, path, node.body, current_constant: constant.name, namespace: constant.name.split('::'))
      end

      def visit_def(graph, path, node, current_constant:, namespace:)
        if current_constant && (constant = graph.constants_named(current_constant).find do |candidate|
          candidate.path == path
        end)
          if node.receiver
            constant.add_class_method(node.name, location: SourceLocation.from_prism(path, node.location))
          else
            constant.add_instance_method(node.name, location: SourceLocation.from_prism(path, node.location))
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

        visit_children(graph, path, node, current_constant: current_constant, namespace: namespace)
      end

      def visit_call(graph, path, node, current_constant:, namespace:)
        unless node.message
          return visit_children(graph, path, node, current_constant: current_constant,
                                                   namespace: namespace)
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

        record_generated_methods(graph, path, node, message, current_constant, location)

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
              location: location
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

        visit_children(graph, path, node, current_constant: current_constant, namespace: namespace)
      end

      def add_constant_reference(graph, path, node, current_constant)
        name = constant_reference_name(node)
        return unless name

        graph.add_edge(
          type: :references_constant,
          from_path: path,
          from_constant: current_constant,
          to: name,
          location: SourceLocation.from_prism(path, node.location)
        )
      end

      def visit_children(graph, path, node, current_constant:, namespace:)
        node.child_nodes.compact.each do |child|
          visit(graph, path, child, current_constant: current_constant, namespace: namespace)
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

      # attr_* and unprefixed delegate calls define instance methods; without
      # them, a class calling its own reader looks like a foreign call.
      def record_generated_methods(graph, path, node, message, current_constant, location)
        return unless current_constant && node.receiver.nil?
        return unless ATTR_MESSAGES.key?(message) || message == :delegate

        constant = graph.constants_named(current_constant).find { |candidate| candidate.path == path }
        return unless constant

        names = symbol_arguments(node)
        return if message == :delegate && keyword_argument?(node, :prefix)

        names.each do |name|
          kinds = ATTR_MESSAGES.fetch(message, %i[reader])
          constant.add_instance_method(name, location: location) if kinds.include?(:reader)
          constant.add_instance_method(:"#{name}=", location: location) if kinds.include?(:writer)
        end
      end

      def symbol_arguments(node)
        node.arguments&.arguments&.filter_map do |argument|
          argument.unescaped.to_sym if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
        end || []
      end

      def keyword_argument?(node, name)
        node.arguments&.arguments&.any? do |argument|
          argument.is_a?(Prism::KeywordHashNode) && argument.elements.any? do |element|
            element.is_a?(Prism::AssocNode) && element.key.is_a?(Prism::SymbolNode) &&
              element.key.unescaped.to_sym == name
          end
        end
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
        name = (constant_reference_name(receiver_node) if constant_node?(receiver_node)) || receiver_node&.slice
        "#{name}##{node.message}"
      end

      # class Users::RolesController inside module Admin defines
      # Admin::Users::RolesController, so compact paths join the namespace too.
      def qualified_constant_name(node, namespace)
        raw = constant_reference_name(node)
        absolute = node.respond_to?(:full_name_parts) && node.full_name_parts.first == :""

        if absolute || namespace.empty?
          raw
        else
          "#{namespace.join('::')}::#{raw}"
        end
      end

      # nil when the path has dynamic parts (self.class::FOO): there is no
      # static name to check against.
      def constant_reference_name(node)
        node.full_name.to_s.sub(/\A::/, '')
      rescue Prism::ConstantPathNode::DynamicPartsInConstantPathError
        nil
      end

      def constant_node?(node)
        node.is_a?(Prism::ConstantReadNode) || node.is_a?(Prism::ConstantPathNode)
      end
    end
  end
end
