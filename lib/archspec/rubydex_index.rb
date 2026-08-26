# frozen_string_literal: true

require 'rubydex'
require 'set'

require_relative 'error'
require_relative 'source_location'

module ArchSpec
  # Translates Rubydex's semantic index into the small graph ArchSpec's rules
  # consume. Rubydex owns Ruby semantics here: declarations, constant
  # resolution, ancestry and methods all come from its resolved graph. The
  # Prism pass in Analyzer adds only syntax facts Rubydex does not expose.
  class RubydexIndex
    attr_reader :call_resolutions

    def initialize(paths, syntax:, method_names: [])
      @paths = paths.map { |path| File.expand_path(path) }.to_set
      @syntax = syntax
      @configured_method_names = method_names.to_set
      @call_resolutions = {}
    end

    def populate(graph)
      @index = ::Rubydex::Graph.new
      @index.encoding = 'utf8'
      @index.index_all(paths.to_a.sort)
      @index.resolve

      add_constants(graph)
      add_methods(graph)
      add_ancestry(graph)
      add_constant_references(graph)
      resolve_call_sites
      add_diagnostics(graph)
      graph
    rescue ::Rubydex::Error, IOError, SystemCallError => error
      raise Error, "Rubydex could not index the project: #{error.message.lines.first&.strip}"
    end

    private

    attr_reader :paths, :syntax, :configured_method_names

    def add_constants(graph)
      declarations_with_workspace_definitions.each do |declaration, definition, path|
        name = canonical_name(declaration.name)
        next unless name

        location = source_location(path, definition.location)
        name = syntax.declaration_name(name, path, location)
        kind = syntax.declaration_kind(name, path) || kind_of(declaration)
        next unless kind

        constant = graph.add_constant(
          name: name,
          kind: kind,
          path: path,
          location: location,
          nesting: nesting_of(definition, path)
        )
        constant.superclass = syntax.superclass_override(name, path) if constant.class?
      end
    end

    def add_methods(graph)
      workspace_method_definitions.each do |declaration, definition, path|
        owner = method_owner(declaration, definition, path)
        next unless owner

        constant = graph.constants_named(owner.name).find { |candidate| candidate.path == path }
        next unless constant

        location = source_location(path, definition.location)
        signatures = signatures_for(definition)
        alias_target = method_alias_target(definition)
        method_names(declaration, definition).each do |name|
          if owner.scope == :class
            constant.add_class_method(
              name,
              location: location,
              visibility: visibility_of(declaration),
              signatures: signatures,
              alias_target: alias_target
            )
          else
            constant.add_instance_method(
              name,
              location: location,
              visibility: visibility_of(declaration),
              signatures: signatures,
              alias_target: alias_target
            )
          end
        end
      end
    end

    def add_ancestry(graph)
      workspace_namespaces.each do |declaration|
        declaration.definitions.each do |definition|
          path = path_of(definition.location)
          next unless paths.include?(path)

          name = canonical_name(declaration.name)
          next unless name

          name = syntax.declaration_name(name, path, source_location(path, definition.location))
          constant = graph.constants_named(name).find { |candidate| candidate.path == path }
          next unless constant

          dynamic_superclass = syntax.superclass_override(name, path)
          if dynamic_superclass
            constant.superclass = dynamic_superclass
          elsif definition.respond_to?(:superclass) && definition.superclass
            target, resolved = reference_target(definition.superclass, path)
            fallback = syntax.superclass_fallback(name, path)
            target = fallback if fallback
            constant.superclass = resolved || target
            add_ancestry_edge(graph, :inherits_from, name, definition, definition.superclass, target, resolved)
          end

          next unless definition.respond_to?(:mixins)

          definition.mixins.each do |mixin|
            kind = mixin_kind(mixin)
            next unless kind

            reference = mixin.constant_reference
            location = source_location(path, reference.location)
            next unless syntax.constant_name_at(path, location)

            target, resolved = reference_target(reference, path)
            constant.add_mixin(kind, resolved || target)
            add_ancestry_edge(graph, :"#{kind}s", name, definition, reference, target, resolved)
          end
        end
      end
    end

    def add_ancestry_edge(graph, type, name, definition, reference, target, resolved)
      path = path_of(definition.location)
      graph.add_edge(
        type: type,
        from_path: path,
        from_constant: name,
        to: target,
        resolved_to: resolved,
        location: source_location(path, reference.location),
        lexical_nesting: nesting_of(definition, path)
      )
    end

    def add_constant_references(graph)
      syntax.constant_sites.each do |site|
        declaration = @index.resolve_constant(site.name, site.nesting)
        resolved = semantic_name(declaration) if declaration

        graph.add_edge(
          type: :references_constant,
          from_path: site.path,
          from_constant: site.owner,
          to: site.name,
          resolved_to: resolved,
          location: site.location,
          lexical_nesting: site.nesting
        )
      end
    end

    def declarations_with_workspace_definitions
      declarations.flat_map do |declaration|
        kind = kind_of(declaration)
        next [] unless kind

        declaration.definitions.filter_map do |definition|
          path = path_of(definition.location)
          [declaration, definition, path] if paths.include?(path)
        end
      end.sort_by do |declaration, definition, path|
        [path, definition.location.start_line, definition.location.start_column, declaration.name]
      end
    end

    def workspace_method_definitions
      declarations.grep(::Rubydex::Method).flat_map do |declaration|
        declaration.definitions.filter_map do |definition|
          path = path_of(definition.location)
          [declaration, definition, path] if paths.include?(path)
        end
      end.sort_by do |declaration, definition, path|
        [path, definition.location.start_line, definition.location.start_column, declaration.name]
      end
    end

    def workspace_namespaces
      declarations.select do |declaration|
        declaration.is_a?(::Rubydex::Namespace) && !declaration.is_a?(::Rubydex::SingletonClass) &&
          declaration.definitions.any? { |definition| paths.include?(path_of(definition.location)) }
      end.sort_by(&:name)
    end

    def kind_of(declaration)
      case declaration
      when ::Rubydex::Class then :class
      when ::Rubydex::Module then :module
      when ::Rubydex::Constant, ::Rubydex::ConstantAlias then :constant
      end
    end

    def method_owner(declaration, definition, path)
      override = syntax.method_owner_override(path, source_location(path, definition.location))
      return override if override

      owner = declaration.owner
      scope = owner.is_a?(::Rubydex::SingletonClass) ? :class : :instance
      owner = attached(owner)
      name = canonical_name(owner&.name)
      location = source_location(path, definition.location)
      syntax.method_owner(name && syntax.declaration_name(name, path, location), scope)
    end

    def method_names(declaration, definition)
      name = declaration.unqualified_name.to_s.delete_suffix('()').to_sym
      case definition
      when ::Rubydex::AttrAccessorDefinition then [name, :"#{name}="]
      when ::Rubydex::AttrWriterDefinition then [:"#{name}="]
      else [name]
      end
    end

    def signatures_for(definition)
      return [] unless definition.respond_to?(:signatures)

      definition.signatures.map do |signature|
        MethodSignature.new(
          signature.positional_parameters.length + signature.post_parameters.length,
          signature.optional_positional_parameters.length,
          !signature.rest_positional_parameter.nil?,
          signature.keyword_parameters.map(&:name),
          signature.optional_keyword_parameters.map(&:name),
          !signature.rest_keyword_parameter.nil?,
          !signature.block_parameter.nil?,
          !signature.forward_parameter.nil?
        )
      end
    end

    def method_alias_target(definition)
      return unless definition.is_a?(::Rubydex::MethodAliasDefinition) && definition.target

      definition.target.unqualified_name.to_s.delete_suffix('()').to_sym
    end

    def resolve_call_sites
      names = relevant_call_names
      return if names.empty?

      syntax.call_sites.each do |site|
        next unless names.include?(site.name)

        if site.receiver_name
          declaration = @index.resolve_constant(site.receiver_name, site.nesting)
          receiver = semantic_name(declaration) if declaration
          @call_resolutions[site] = syntax.class::CallResolution.new(receiver, :class) if receiver
        elsif site.receiver == :none && site.owner
          @call_resolutions[site] = syntax.class::CallResolution.new(site.owner, site.scope)
        end
      end
    end

    def relevant_call_names
      aliases = declarations.grep(::Rubydex::Method).each_with_object({}) do |declaration, map|
        targets = declaration.definitions.filter_map { |definition| method_alias_target(definition) }
        map[declaration.unqualified_name.to_s.delete_suffix('()').to_sym] = targets unless targets.empty?
      end

      names = configured_method_names.dup
      loop do
        added = aliases.filter_map do |name, targets|
          name if targets.any? { |target| names.include?(target) } && !names.include?(name)
        end
        break if added.empty?

        names.merge(added)
      end
      names
    end

    def add_diagnostics(graph)
      @index.diagnostics.each do |diagnostic|
        path = path_of(diagnostic.location)
        next unless paths.include?(path)

        graph.add_analysis_diagnostic(
          rule: diagnostic.rule.rule_name,
          message: diagnostic.message,
          location: source_location(path, diagnostic.location)
        )
      end
    end

    def reference_target(reference, path)
      written = syntax.constant_name_at(path, source_location(path, reference.location))

      if reference.is_a?(::Rubydex::ResolvedConstantReference)
        target = attached(reference.declaration)
        name = semantic_name(target)
        [written || name, name]
      else
        [written || reference.name.to_s.sub(/\A<(.+)>\z/, '\\1'), nil]
      end
    end

    def mixin_kind(mixin)
      case mixin
      when ::Rubydex::Include then :include
      when ::Rubydex::Prepend then :prepend
      when ::Rubydex::Extend then :extend
      end
    end

    def visibility_of(declaration)
      declaration.respond_to?(:visibility) ? declaration.visibility.to_sym : :public
    end

    def attached(declaration)
      declaration.is_a?(::Rubydex::SingletonClass) ? declaration.attached_class : declaration
    end

    def nesting_of(definition, path)
      definition.lexical_nesting.filter_map do |owner|
        declaration = owner.declaration
        name = canonical_name(declaration&.name)
        syntax.declaration_name(name, path, source_location(path, definition.location)) if name
      end
    end

    def semantic_name(declaration, path = nil)
      declaration = attached(declaration)
      name = canonical_name(declaration.name)
      syntax.declaration_name(name, path || workspace_definition_path(declaration)) if name
    end

    def workspace_definition_path(declaration)
      attached(declaration).definitions.each do |definition|
        path = path_of(definition.location)
        return path if paths.include?(path)
      end
      nil
    end

    def declarations
      @declarations ||= @index.declarations.to_a
    end

    def canonical_name(name)
      return if name.to_s.include?('<anonymous>')

      name.to_s.gsub(/::<[^>]+>/, '')
    end

    def source_location(path, location)
      SourceLocation.new(
        path,
        location.start_line + 1,
        location.start_column + 1,
        location.end_line + 1,
        location.end_column + 1
      )
    end

    def path_of(location)
      File.expand_path(location.to_file_path)
    rescue ::Rubydex::Location::NotFileUriError
      location.uri.to_s
    end
  end
end
