# frozen_string_literal: true

module ArchSpec
  # Normalizes the explicit ActiveSupport::Concern DSL after semantic indexing.
  # Callback bodies retain lexical constant references, but their mixins and
  # methods are installed on the consumer. No application code is executed.
  # Source ownership is normalized here; established effects are emitted through
  # Facts::Builder, using the same application path as external producers.
  class ConcernSemantics
    ModuleBody = Data.define(:name, :path, :body)
    Callback = Data.define(:kind, :methods, :mixins, :calls)
    MIXINS = { includes: :include, prepends: :prepend, extends: :extend }.freeze

    def initialize
      @modules = []
      @callbacks = Hash.new { |hash, key| hash[key] = [] }
      @dependencies = Hash.new { |hash, key| hash[key] = [] }
    end

    def record_module(name, path, body)
      @modules << ModuleBody.new(name, path, body) if body.is_a?(Prism::StatementsNode)
    end

    def apply(graph)
      @graph = graph
      @mixin_edges = graph.edges.select { |edge| MIXINS.key?(edge.type) }
                          .group_by { |edge| [edge.from_constant, edge.from_path] }
      @concerns = @modules.select { |mod| extends_concern?(mod) }.map(&:name).to_set
      return if @concerns.empty?

      @facts = Facts::Builder.new(graph, producer: 'active_support_concern')
      normalize_blocks
      defer_dependencies
      rebuild_mixins
      install_consumers
      @concerns.each do |name|
        source = graph.constants_named("#{name}::ClassMethods").first
        @facts.expose_methods(source: source, owner: graph.constants_named(name).first, scope: :class) if source
      end
      @facts.apply
    end

    private

    attr_reader :graph

    def extends_concern?(mod)
      mod.body.body.any? do |node|
        next false unless node.is_a?(Prism::CallNode) && node.name == :extend
        next false unless node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode)

        span = SourceLocation.from_prism(mod.path, node.location)
        @mixin_edges.fetch([mod.name, mod.path], []).any? do |edge|
          edge.type == :extends && edge.from_constant == mod.name && within?(span, edge.location) &&
            graph.resolve_edge_constant(edge) == 'ActiveSupport::Concern'
        end
      end
    end

    def install_consumers
      events = graph.edges.select { |edge| MIXINS.key?(edge.type) }.group_by { |edge| [edge.from_constant, edge.from_path] }
      events.each do |(name, path), edges|
        next if @concerns.include?(name)
        next unless edges.any? do |edge|
          edge.type != :extends && @concerns.include?(graph.resolve_edge_constant(edge))
        end

        consumer = graph.constants_named(name).find { |node| node.path == path }
        next unless consumer

        consumer.mixins.each_value(&:clear)
        visited = Set.new
        edges.sort_by { |edge| [edge.location.line, edge.location.column] }.each do |edge|
          target = graph.resolve_edge_constant(edge)
          kind = MIXINS.fetch(edge.type)
          if kind != :extend && @concerns.include?(target)
            install_concern(consumer, target, kind, edge, visited)
          else
            add_mixin(consumer, kind, target, edge)
          end
        end
      end
    end

    def normalize_blocks
      @modules.each do |mod|
        next unless @concerns.include?(mod.name)

        mod.body.body.each do |node|
          next unless node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
          next unless %i[class_methods included prepended].include?(node.name)
          next unless node.arguments.nil? && node.block.is_a?(Prism::BlockNode)
          next if graph.constants_named(mod.name).any? { |constant| constant.class_methods.include?(node.name) }

          location = SourceLocation.from_prism(mod.path, node.block.location)
          if node.name == :class_methods
            normalize_class_methods(mod, location)
          else
            defer_callback(mod, node, location)
          end
        end
      end
    end

    def normalize_class_methods(mod, location)
      name = "#{mod.name}::ClassMethods"
      target = graph.add_constant(name: name, kind: :module, path: mod.path,
                                 location: location, nesting: [mod.name])
      extract_methods(mod, location).each { |method| @facts.method_definition(owner: target, definition: method) }
      graph.edges.map! do |edge|
        next edge unless edge.from_constant == mod.name && within?(location, edge.location)

        edge.with(from_constant: name,
                  resolved_receiver: edge.resolved_receiver == mod.name ? name : edge.resolved_receiver)
      end
    end

    def defer_callback(mod, node, location)
      methods = extract_methods(mod, location)
      mixins = graph.edges.select do |edge|
        edge.from_constant == mod.name && MIXINS.key?(edge.type) && within?(location, edge.location)
      end
      graph.edges.reject! { |edge| mixins.include?(edge) }
      statements = node.block.body.is_a?(Prism::StatementsNode) ? node.block.body.body : []
      direct = statements.select do |statement|
        statement.is_a?(Prism::DefNode) ||
          (statement.is_a?(Prism::CallNode) && statement.block.nil? &&
           (statement.receiver.nil? || statement.receiver.is_a?(Prism::SelfNode)))
      end
                         .map { |statement| SourceLocation.from_prism(mod.path, statement.location) }
      certain_methods = methods.select { |method| direct.any? { |span| within?(span, method.location) } }
      certain_mixins = mixins.select { |edge| direct.any? { |span| within?(span, edge.location) } }
      calls = graph.edges.select do |edge|
        edge.type == :calls_named_method && edge.receiver == :none && edge.from_constant == mod.name &&
          (direct.include?(edge.location) || certain_methods.any? { |method| within?(method.location, edge.location) })
      end
      @callbacks[mod.name] << Callback.new(node.name, certain_methods, certain_mixins, calls)
      return if methods == certain_methods && mixins == certain_mixins

      source = graph.constants_named(mod.name).find { |constant| constant.path == mod.path }
      @facts.gap(source: source, message: "conditional #{node.name} callback", location: location)
    end

    def extract_methods(mod, location)
      graph.constants_named(mod.name).flat_map do |constant|
        selected = constant.method_definitions.select { |method| within?(location, method.location) }
        constant.method_definitions.reject! { |method| selected.include?(method) }
        constant.instance_methods.replace(constant.method_definitions.select { |method| method.scope == :instance }.map(&:name))
        constant.class_methods.replace(constant.method_definitions.select { |method| method.scope == :class }.map(&:name))
        selected
      end
    end

    def defer_dependencies
      graph.edges.reject! do |edge|
        next false unless @concerns.include?(edge.from_constant) && %i[includes prepends].include?(edge.type)
        next false unless @concerns.include?(graph.resolve_edge_constant(edge))

        @dependencies[edge.from_constant] << edge
        true
      end
    end

    def rebuild_mixins
      affected = @concerns | @concerns.map { |name| "#{name}::ClassMethods" }.to_set
      mixins = graph.edges.select { |edge| MIXINS.key?(edge.type) }
                    .group_by { |edge| [edge.from_constant, edge.from_path] }
      graph.constants.each do |constant|
        next unless affected.include?(constant.name)

        constant.mixins.each_value(&:clear)
        mixins.fetch([constant.name, constant.path], []).each do |edge|
          constant.add_mixin(MIXINS.fetch(edge.type), graph.resolve_edge_constant(edge))
        end
      end
    end

    def install_concern(consumer, name, kind, origin, visited)
      return if visited.include?([consumer.name, name])

      visited.add([consumer.name, name])
      @dependencies[name].each do |dependency|
        target = graph.resolve_edge_constant(dependency)
        install_concern(consumer, target, kind, dependency, visited)
      end
      add_mixin(consumer, kind, name, origin)
      class_methods = "#{name}::ClassMethods"
      unless graph.constants_named(class_methods).empty?
        add_mixin(consumer, kind == :prepend ? :singleton_prepend : :extend, class_methods, origin)
      end
      callback_kind = kind == :prepend ? :prepended : :included
      @callbacks[name].select { |callback| callback.kind == callback_kind }.each do |callback|
        callback.mixins.each do |edge|
          target = graph.resolve_edge_constant(edge)
          mixin_kind = MIXINS.fetch(edge.type)
          if @concerns.include?(target) && mixin_kind != :extend
            install_concern(consumer, target, mixin_kind, edge, visited)
          else
            add_mixin(consumer, mixin_kind, target, edge)
          end
        end
        callback.methods.each do |method|
          @facts.method_definition(owner: consumer, definition: method, installation: origin.location)
        end
        callback.calls.each do |edge|
          method = callback.methods.find { |definition| within?(definition.location, edge.location) }
          @facts.bind_receiver(edge: edge, receiver: consumer.name, scope: method ? method.scope : :class)
        end
      end
    end

    def add_mixin(consumer, kind, target, origin)
      @facts.mixin(owner: consumer, kind: kind, target: target, location: origin.location)
    end

    def within?(outer, inner)
      outer.path == inner.path &&
        ([outer.line, outer.column] <=> [inner.line, inner.column]) <= 0 &&
        ([outer.end_line, outer.end_column] <=> [inner.end_line, inner.end_column]) >= 0
    end
  end
end
