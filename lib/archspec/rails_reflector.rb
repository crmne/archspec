# frozen_string_literal: true

module ArchSpec
  # The built-in Rails producer. <tt>archspec reflect</tt> boots the
  # application in a separate process and records what Rails itself resolved:
  # association targets and generated methods, custom validator classes, and
  # the effects conditional concern callbacks had on each consumer. Normal
  # analysis never requires Rails.
  module RailsReflector
    extend self

    ASSOCIATIONS = %i[belongs_to has_one has_many has_and_belongs_to_many].freeze
    # Macros that declare associations under derived names.
    GENERATED_ASSOCIATIONS = {
      has_one_attached: [[:has_one, '%s_attachment'], [:has_one, '%s_blob']],
      has_many_attached: [[:has_many, '%s_attachments'], [:has_many, '%s_blobs']],
      has_rich_text: [[:has_one, 'rich_text_%s']]
    }.freeze
    VALIDATIONS = %i[validates validates!].freeze
    Site = Data.define(:macro, :name, :owner, :location)
    # Module#name, immune to classes that redefine +name+ with other meanings.
    MODULE_NAME = Module.instance_method(:name)

    def boot(root)
      environment = File.join(root, 'config/environment.rb')
      raise Error, "no #{environment} found; the rails producer requires a Rails application" unless File.file?(environment)

      ENV['RAILS_ENV'] ||= 'development'
      require environment
      eager_load_application
    end

    # Records every Rails fact for the loaded application.
    def capture(facts, models: active_record_models, validated: validated_classes)
      sites = macro_sites(facts.graph, models | validated)
      associations(facts, models, sites)
      validators(facts, validated, sites)
      concerns(facts)
      facts
    end

    def associations(facts, models, sites = macro_sites(facts.graph, models))
      graph = facts.graph
      reflections = models.flat_map(&:reflect_on_all_associations)
                          .uniq { |reflection| [reflection.active_record.name, reflection.name] }
      reflections.sort_by { |reflection| [reflection.active_record.name.to_s, reflection.name.to_s] }.each do |reflection|
        model = reflection.active_record
        next if model.name.nil? || graph.constants_named(model.name).empty?

        ancestors = graph.ancestor_names(model.name).first | Set[model.name]
        candidates = sites.fetch([reflection.macro, reflection.name.to_s], []).select { |site| ancestors.include?(site.owner) }
        source = source_node(graph, model, candidates)
        next unless source

        if candidates.size != 1
          facts.gap(source: source, location: source.location,
            message: "association #{model.name}.#{reflection.name}: no unique literal declaration")
          next
        end
        site = candidates.first
        generated = model.generated_association_methods.instance_methods(false).map(&:to_s)
        names = [reflection.name.to_s, "#{reflection.name}="] & generated
        facts.methods(owner: source, location: site.location, names: names.sort) unless names.empty?
        if reflection.polymorphic?
          facts.gap(source: source, location: site.location, message: "polymorphic association #{model.name}.#{reflection.name}")
          next
        end
        begin
          facts.reference(source: source, target: reflection.klass, location: site.location)
        rescue NameError, ArgumentError, ActiveRecord::ActiveRecordError, Error => error
          facts.gap(source: source, location: site.location,
            message: "unresolved association #{model.name}.#{reflection.name}: #{error.message.lines.first.strip}")
        end
      end
    end

    # A validation such as <tt>validates :email, email: true</tt> names its
    # validator class only by convention. The loaded model knows the class
    # Rails resolved; the literal +validates+ call supplies the location.
    def validators(facts, classes, sites = macro_sites(facts.graph, classes))
      graph = facts.graph
      classes.to_h { |klass| [MODULE_NAME.bind_call(klass), klass] }.sort.each do |class_name, klass|
        next if class_name.nil? || graph.constants_named(class_name).empty?

        ancestors = graph.ancestor_names(class_name).first | Set[class_name]
        klass.validators.map(&:class).uniq.map { |validator| MODULE_NAME.bind_call(validator) }.compact.sort.each do |name|
          next if name.start_with?('ActiveModel::', 'ActiveRecord::')

          candidates = VALIDATIONS.flat_map { |macro| sites.fetch([macro, :validator], []) }.select do |site|
            ancestors.include?(site.owner) && validator_key?(site.name, name)
          end
          if candidates.empty?
            next if referenced?(graph, ancestors, name)

            source = source_node(graph, klass, [])
            if source
              facts.gap(source: source, location: source.location,
                message: "validator #{name} on #{class_name}: no literal declaration")
            end
            next
          end
          candidates.each do |site|
            source = site_source(graph, klass, site)
            facts.reference(source: source, target: name, location: site.location) if source
          end
        end
      end
    end

    # Conditional concern callbacks are gaps in static analysis. Once the
    # application is loaded, each consumer shows which candidate mixins and
    # methods it actually received. An effect is recorded only when exactly one
    # candidate explains it; the gap is resolved only when every consumer could
    # be inspected and every observed effect was attributed.
    def concerns(facts)
      graph = facts.graph
      callbacks = graph.conditional_callbacks
      return if callbacks.empty?

      unsettled = callbacks.map(&:concern).uniq.reject { |concern| runtime_constant(concern) }.to_set
      consumers(graph, callbacks).each do |node, applicable|
        consumer = runtime_constant(node.name)
        if consumer
          unsettled.merge(observe_mixins(facts, node, consumer, applicable))
          observe_methods(facts, node, consumer, applicable)
        else
          unsettled.merge(applicable.map(&:concern))
        end
      end
      callbacks.each do |callback|
        next if unsettled.include?(callback.concern)

        source = graph.constants_named(callback.concern).find { |constant| constant.path == callback.path }
        facts.resolve(source: source, location: callback.location, message: "conditional #{callback.kind} callback",
          consumers: graph.consumers_of(callback.concern))
      end
    end

    private

    # Loads the application's own code, including engines inside the project,
    # but not installed gems: their models are not analyzed, and loading them
    # can require configuration the chosen environment does not have.
    def eager_load_application
      loader = Rails.autoloaders.main if defined?(Rails.autoloaders)
      return Rails.application.eager_load! unless loader.respond_to?(:dirs) && loader.respond_to?(:eager_load_dir)

      root = "#{Rails.root}/"
      gems = (Gem.path + [defined?(Bundler) ? Bundler.bundle_path.to_s : nil]).compact.map { |path| "#{File.expand_path(path)}/" }
      loader.dirs.select { |dir| dir.start_with?(root) && gems.none? { |gem_dir| dir.start_with?(gem_dir) } }
            .each { |dir| loader.eager_load_dir(dir) }
    end

    def active_record_models
      defined?(ActiveRecord::Base) ? ActiveRecord::Base.descendants.reject(&:abstract_class?).select(&:name) : []
    end

    def validated_classes
      return [] unless defined?(ActiveModel::Validations)

      ObjectSpace.each_object(Class).select { |klass| klass.include?(ActiveModel::Validations) && MODULE_NAME.bind_call(klass) }
    end

    # Returns the concerns whose observed effects could not be attributed to a
    # single candidate declaration.
    def observe_mixins(facts, node, consumer, callbacks)
      graph = facts.graph
      instance, = graph.ancestor_names(node.name)
      singleton, = graph.ancestor_names(node.name, scope: :class)
      candidates = callbacks.flat_map { |callback| callback.mixins.map { |mixin| [callback, mixin] } }
      candidates.group_by { |_, mixin| [mixin.kind, mixin.target] }.each_with_object(Set.new) do |((kind, target), sites), ambiguous|
        module_object = runtime_constant(target)
        next unless module_object.is_a?(Module)

        observed = kind == :extend ? consumer.singleton_class.include?(module_object) : consumer.include?(module_object)
        next unless observed && !(kind == :extend ? singleton : instance).include?(target)
        next ambiguous.merge(sites.map { |callback, _| callback.concern }) unless sites.one?

        facts.mixin(owner: node, target: target, kind: kind, location: sites.first.last.location)
      end
    end

    def observe_methods(facts, node, consumer, callbacks)
      callbacks.flat_map(&:methods).each do |definition|
        method = begin
          definition.scope == :class ? consumer.method(definition.name) : consumer.instance_method(definition.name)
        rescue NameError
          nil
        end
        path, line = method&.source_location
        next unless path && File.expand_path(path) == definition.location.path && line == definition.location.line

        facts.method_definition(owner: node, definition: definition, installation: definition.location)
      end
    end

    # Each analyzed consumer with the conditional callbacks it runs: included
    # callbacks for an include, prepended callbacks for a prepend.
    def consumers(graph, callbacks)
      concerns = callbacks.map(&:concern).to_set
      graph.constants.each_with_object({}) do |node, found|
        next if node.namespace_only || concerns.include?(node.name) || found.key?(node.name)

        applicable = callbacks.select do |callback|
          node.mixins.fetch(callback.kind == :prepended ? :prepend : :include).include?("::#{callback.concern}")
        end
        found[node.name] = [node, applicable] unless applicable.empty?
      end.values
    end

    def runtime_constant(name)
      Object.const_get(name)
    rescue NameError, ArgumentError
      nil
    end

    def validator_key?(key, validator)
      class_name = "#{key.to_s.camelize}Validator"
      validator == class_name || validator.end_with?("::#{class_name}")
    end

    def referenced?(graph, ancestors, name)
      graph.dependency_edges.any? { |edge| ancestors.include?(edge.from_constant) && graph.resolve_edge_constant(edge) == name }
    end

    def site_source(graph, klass, site)
      owner = graph.constants_named(site.owner).find { |node| node.class? && node.path == site.location.path }
      owner || source_node(graph, klass, [site])
    end

    def source_node(graph, model, candidates)
      nodes = graph.constants_named(model.name)
      direct = nodes.select { |node| candidates.any? { |site| site.owner == model.name && site.location.path == node.path } }
      return direct.first if direct.one?

      location = Object.const_source_location(model.name)
      nodes.find { |node| location && node.path == File.expand_path(location.first) } || nodes.find { |node| !node.namespace_only }
    end

    # Literal association and validation declarations, found by parsing only
    # the files that define the given classes and their analyzed ancestors.
    def macro_sites(graph, classes)
      names = classes.filter_map { |klass| MODULE_NAME.bind_call(klass) }.flat_map { |name| graph.ancestor_names(name).first.to_a << name }.to_set
      paths = names.flat_map { |name| graph.constants_named(name).map(&:path) }.uniq.sort
      owners = graph.edges.select { |edge| edge.type == :calls_named_method && paths.include?(edge.from_path) }
                    .to_h { |edge| [[edge.from_path, edge.location], edge.from_constant] }
      sites = []
      paths.each { |path| collect_sites(owners, path, Prism.parse_file(path).value, sites) }
      sites.group_by { |site| [site.macro, site.name.is_a?(String) ? site.name : :validator] }
    end

    def collect_sites(owners, path, node, sites)
      return unless node
      return if node.is_a?(Prism::DefNode)

      if node.is_a?(Prism::CallNode) && (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        location = SourceLocation.from_prism(path, node.location)
        arguments = node.arguments&.arguments || []
        argument = arguments.first
        literal = argument.unescaped if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
        if ASSOCIATIONS.include?(node.name)
          sites << Site.new(node.name, literal, owners[[path, location]], location) if literal
        elsif GENERATED_ASSOCIATIONS.key?(node.name)
          GENERATED_ASSOCIATIONS.fetch(node.name).each do |macro, pattern|
            sites << Site.new(macro, format(pattern, literal), owners[[path, location]], location) if literal
          end
        elsif VALIDATIONS.include?(node.name)
          validation_keys(arguments).each do |key|
            sites << Site.new(node.name, key.to_sym, owners[[path, location]], location)
          end
        end
      end
      node.compact_child_nodes.each { |child| collect_sites(owners, path, child, sites) }
    end

    def validation_keys(arguments)
      arguments.grep(Prism::KeywordHashNode).flat_map(&:elements).filter_map do |element|
        key = element.key if element.is_a?(Prism::AssocNode)
        key.unescaped if key.is_a?(Prism::SymbolNode) || key.is_a?(Prism::StringNode)
      end
    end
  end

  producer :rails do
    sources 'app/models/**/*.rb', '**/app/models/**/*.rb'
    env 'RAILS_ENV'
    boot { |root| RailsReflector.boot(root) }
    capture { |facts| RailsReflector.capture(facts) }
  end
end
