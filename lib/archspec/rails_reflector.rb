# frozen_string_literal: true

require 'open3'
require 'rbconfig'

module ArchSpec
  # Produces facts from real Active Record reflection. The parent command
  # starts Rails explicitly; normal analysis never requires Active Record.
  module RailsReflector
    extend self

    MACROS = %i[belongs_to has_one has_many has_and_belongs_to_many].freeze
    Site = Data.define(:macro, :name, :owner, :location)

    def run(config_path:, root:, output_path:, environment:)
      rails = File.join(root, 'bin/rails')
      raise Error, "no #{rails} found; reflection requires a Rails application" unless File.file?(rails)

      environment_variables = {
        'ARCHSPEC_REFLECTION_CONFIG' => File.expand_path(config_path),
        'ARCHSPEC_REFLECTION_OUTPUT' => output_path
      }
      stdout, stderr, status = Open3.capture3(environment_variables, RbConfig.ruby, rails,
        'runner', '-e', environment, File.expand_path('reflect_runner.rb', __dir__), chdir: root)
      raise Error, "Rails reflection failed (exit #{status.exitstatus}):\n#{stderr}#{stdout}" unless status.success?

      stdout
    rescue SystemCallError => error
      raise Error, "could not start Rails reflection: #{error.message}"
    end

    def capture(graph, models:, environment:, facts_path: 'archspec_facts')
      sites = association_sites(graph).group_by { |site| [site.macro, site.name] }
      facts = Facts::Builder.new(graph, producer: 'active_record')
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
        unless names.empty?
          facts.methods(owner: source, location: site.location, names: names.sort)
        end
        if reflection.polymorphic?
          facts.gap(source: source, location: site.location, message: "polymorphic association #{model.name}.#{reflection.name}")
          next
        end
        begin
          target = reflection.klass.name
          raise Error, 'association target is anonymous' if target.nil? || target.empty?

          facts.reference(source: source, target: target, location: site.location)
        rescue NameError, ArgumentError, ActiveRecord::ActiveRecordError, Error => error
          facts.gap(source: source, location: site.location,
            message: "unresolved association #{model.name}.#{reflection.name}: #{error.message.lines.first.strip}")
        end
      end
      facts.to_document(environment: environment, facts_path: facts_path)
    end

    private

    def source_node(graph, model, candidates)
      nodes = graph.constants_named(model.name)
      direct = nodes.select { |node| candidates.any? { |site| site.owner == model.name && site.location.path == node.path } }
      return direct.first if direct.one?

      location = Object.const_source_location(model.name)
      nodes.find { |node| location && node.path == File.expand_path(location.first) } || nodes.find { |node| !node.namespace_only }
    end

    def association_sites(graph)
      owners = graph.edges.select { |edge| edge.type == :calls_named_method }
                    .to_h { |edge| [[edge.from_path, edge.location], edge.from_constant] }
      graph.files.keys.flat_map do |path|
        result = []
        collect_sites(owners, path, Prism.parse_file(path).value, result)
        result
      end
    end

    def collect_sites(owners, path, node, sites)
      return unless node
      return if node.is_a?(Prism::DefNode)

      if node.is_a?(Prism::CallNode) && MACROS.include?(node.name) &&
         (node.receiver.nil? || node.receiver.is_a?(Prism::SelfNode))
        argument = node.arguments&.arguments&.first
        if argument.is_a?(Prism::SymbolNode) || argument.is_a?(Prism::StringNode)
          location = SourceLocation.from_prism(path, node.location)
          sites << Site.new(node.name, argument.unescaped, owners[[path, location]], location)
        end
      end
      node.compact_child_nodes.each { |child| collect_sites(owners, path, child, sites) }
    end
  end
end
