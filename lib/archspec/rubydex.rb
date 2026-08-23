# frozen_string_literal: true

require 'fileutils'
require 'pathname'
require 'set'

require_relative 'error'
require_relative 'facts'
require_relative 'version'

module ArchSpec
  # Writes the facts file a second resolver can add to the parser's: constant
  # references Rubydex resolved to one declaration where the parser's lexical
  # lookup found nothing. Rubydex reads the workspace and its bundle, so the
  # targets it names may live in a gem; the determination says which side of
  # that boundary answered. The same discipline covers what else Rubydex
  # states about the workspace: a superclass or mixin the parser has none
  # for, a method it did not see defined, and a call whose receiver Rubydex
  # resolved to a constant. Only <tt>archspec reflect --rubydex</tt> loads the
  # gem, and +check+ merges the file it writes like any other.
  module Rubydex
    extend self

    PRODUCER = 'archspec-rubydex'
    WORKSPACE = 'rubydex-workspace'
    GEM = 'rubydex-gem'
    SINGLETON_SUFFIX = /::<[^>]+>\z/

    Resolution = ValueObject.define(:file, :line, :target, :in_workspace)
    Ancestry = ValueObject.define(:owner, :kind, :target, :file, :line, :in_workspace)
    Definition = ValueObject.define(:owner, :name, :scope, :visibility, :file, :line)
    Call = ValueObject.define(:file, :line, :method, :receiver, :in_workspace)
    MIXIN_KINDS = { 'Rubydex::Include' => 'includes', 'Rubydex::Prepend' => 'prepends',
                    'Rubydex::Extend' => 'extends' }.freeze

    def run(graph, output:, root:)
      found = index(root)
      facts = facts_for(graph, found[:resolutions], misses: found[:misses], engine_version: ::Rubydex::VERSION,
                        ancestry: found[:ancestry], definitions: found[:definitions], calls: found[:calls])
      FileUtils.mkdir_p(File.dirname(output))
      Facts.write(output, commit: Facts.commit_for(root), dirty: Facts.dirty?(root), **facts)
      facts
    end

    # Turns Rubydex resolutions into references the parser did not already
    # have. Free of the gem so the comparison is tested with stand-ins: a
    # resolution is a file, a line, the resolved target and whether the
    # target is defined under the root.
    def facts_for(graph, resolutions, misses: {}, engine_version: nil, ancestry: [], definitions: [], calls: [])
      counts = Hash.new(0)
      misses.each { |cause, count| counts[cause.to_s] += count }
      references = []
      by_line = parser_edges_by_line(graph)

      resolutions.each do |resolution|
        path = File.expand_path(resolution.file, graph.root)
        next counts['outside_source'] += 1 unless graph.files.key?(path)
        next counts['declaration'] += 1 if declared_at?(graph, path, resolution.line, resolution.target)

        owner = owner_for(graph, path, resolution.line)
        next counts['self'] += 1 if owner == graph.resolve_constant_reference("::#{resolution.target}")

        verdict = compare(graph, by_line.fetch([path, resolution.line], nil), resolution.target)
        next counts[verdict.to_s] += 1 unless verdict == :written

        references << FactsReference.new(
          owner: owner,
          file: resolution.file,
          line: resolution.line,
          target: resolution.target,
          macro: nil,
          name: nil,
          determination: resolution.in_workspace ? WORKSPACE : GEM
        )
      end

      {
        producer: PRODUCER,
        producer_version: engine_version ? "#{VERSION} rubydex #{engine_version}" : VERSION,
        references: references.uniq,
        generated_methods: [],
        ancestry: ancestry_facts(graph, ancestry, counts),
        definitions: definition_facts(graph, definitions, counts),
        calls: call_facts(graph, calls, counts),
        misses: counts.sort.to_h
      }
    end

    private

    def ancestry_facts(graph, entries, counts)
      entries.filter_map do |entry|
        owner = owner_node(graph, entry.owner, entry.file)
        unless owner
          counts['ancestry_outside_source'] += 1
          next
        end

        wanted = graph.resolve_constant_reference("::#{entry.target}")
        recorded = if entry.kind == 'inherits'
                     owner.superclass && graph.resolve_constant_reference(owner.superclass, owner.name,
                                                                            lexical_nesting: owner.nesting)
                   else
                     owner.mixins.fetch(entry.kind.delete_suffix('s').to_sym).map do |name|
                       graph.resolve_constant_reference(name, owner.name, lexical_nesting: owner.nesting)
                     end.find { |name| name == wanted }
                   end
        if recorded == wanted
          counts['ancestry_already_resolved'] += 1
          next
        end
        if recorded
          counts['ancestry_disagreed'] += 1
          next
        end

        FactsAncestry.new(owner: owner.name, kind: entry.kind, target: entry.target, file: entry.file,
                          line: entry.line, determination: entry.in_workspace ? WORKSPACE : GEM)
      end.uniq
    end

    def definition_facts(graph, entries, counts)
      entries.filter_map do |entry|
        owner = owner_node(graph, entry.owner, entry.file)
        unless owner
          counts['definition_outside_source'] += 1
          next
        end

        known = entry.scope == 'class' ? owner.class_methods : owner.instance_methods
        if known.include?(entry.name.to_sym)
          counts['definition_already_resolved'] += 1
          next
        end

        FactsDefinition.new(owner: owner.name, name: entry.name, scope: entry.scope, visibility: entry.visibility,
                            file: entry.file, line: entry.line, determination: WORKSPACE)
      end.uniq
    end

    # A call is written only where the parser saw a receiver it could not
    # type. A bare call the parser recorded as implicit self is the same
    # fact Rubydex states as a receiver of the enclosing class, not a typed
    # receiver it lacked, so it is counted rather than written.
    def call_facts(graph, entries, counts)
      receivers = graph.edges.each_with_object(Hash.new { |hash, key| hash[key] = Set.new }) do |edge, seen|
        next unless edge.type == :calls_named_method

        seen[[edge.from_path, edge.location.line, edge.to]] << edge.receiver
      end

      entries.filter_map do |entry|
        path = File.expand_path(entry.file, graph.root)
        unless graph.files.key?(path)
          counts['call_outside_source'] += 1
          next
        end
        seen = receivers[[path, entry.line, entry.method]]
        if seen.include?(:constant)
          counts['call_already_resolved'] += 1
          next
        end
        if seen.include?(:none)
          counts['call_implicit_self'] += 1
          next
        end

        FactsCall.new(owner: owner_for(graph, path, entry.line), file: entry.file, line: entry.line,
                      method: entry.method, receiver: entry.receiver,
                      determination: entry.in_workspace ? WORKSPACE : GEM)
      end.uniq
    end

    def owner_node(graph, name, file)
      path = File.expand_path(file, graph.root)
      return nil unless graph.files.key?(path)

      nodes = graph.constants_named(name).reject { |constant| constant.kind == :constant }
      nodes.find { |constant| constant.path == path } || nodes.first
    end

    def index(root)
      load_gem
      gemfile = File.join(root, 'Gemfile')
      raise Error, "no Gemfile at #{root}; reflect --rubydex indexes an application and its bundle" unless File.exist?(gemfile)

      bundle!(root)
      graph = Dir.chdir(root) { build_index }
      collect(graph, File.expand_path(root))
    end

    def bundle!(root)
      return if File.readable?(File.join(root, 'Gemfile.lock'))

      raise Error, "no Gemfile.lock at #{root}; reflect --rubydex indexes the locked bundle, never the workspace alone"
    end

    # The engine lists the workspace and each locked gem's require paths. A
    # Rails engine keeps its constants under app/ beside lib/, which that
    # listing never reaches, so those directories are added and the ones
    # that were absent are counted.
    def build_index
      built = ::Rubydex::Graph.new
      paths = built.workspace_paths
      engine_paths, @engines_without_app = engine_app_paths
      built.index_all(paths + engine_paths)
      built.resolve
      built
    rescue ::Rubydex::Error, IOError, SystemCallError => e
      raise Error, "reflect --rubydex could not index the workspace: #{e.message.lines.first&.strip}"
    end

    def engine_app_paths
      require 'bundler'
      specs = ::Bundler.locked_gems&.specs || []
      present = []
      absent = 0
      specs.each do |lazy_spec|
        spec = Gem::Specification.find_by_name(lazy_spec.name)
        app = File.join(spec.full_gem_path, 'app')
        next unless File.exist?(File.join(spec.full_gem_path, 'lib', lazy_spec.name.tr('-', '/'), 'engine.rb')) ||
                    Dir.exist?(app)

        Dir.exist?(app) ? present << app : absent += 1
      rescue Gem::MissingSpecError
        nil
      end
      [present, absent]
    end

    def load_gem
      require 'rubydex'
    rescue LoadError
      raise Error, 'the rubydex gem is not loadable; add it to the development group and run ' \
                   '`bundle exec archspec reflect --rubydex`'
    end

    def collect(graph, root)
      workspace = "file://#{root}/"
      misses = Hash.new(0)
      resolutions = []
      ancestry = []
      definitions = []
      calls = []

      graph.constant_references.each do |reference|
        uri = reference.location.uri.to_s
        next unless uri.start_with?(workspace)

        unless reference.is_a?(::Rubydex::ResolvedConstantReference)
          misses['unresolved'] += 1
          next
        end

        declaration = attached(reference.declaration)
        next if declaration.nil?

        resolutions << Resolution.new(
          file: uri.delete_prefix(workspace),
          line: reference.location.start_line + 1,
          target: declaration.name.sub(SINGLETON_SUFFIX, ''),
          in_workspace: declaration.definitions.any? { |definition| definition.location.uri.to_s.start_with?(workspace) }
        )
      end

      graph.declarations.each do |declaration|
        next unless declaration.is_a?(::Rubydex::Namespace) && !declaration.is_a?(::Rubydex::SingletonClass)

        collect_ancestry(declaration, workspace, ancestry, misses)
        collect_definitions(declaration, workspace, definitions)
      end

      graph.method_references.each do |reference|
        uri = reference.location.uri.to_s
        next unless uri.start_with?(workspace)

        receiver = attached(reference.receiver)
        next unless receiver.is_a?(::Rubydex::Namespace)

        calls << Call.new(file: uri.delete_prefix(workspace), line: reference.location.start_line + 1,
                          method: reference.name.to_s, receiver: receiver.name.sub(SINGLETON_SUFFIX, ''),
                          in_workspace: in_workspace?(receiver, workspace))
      end

      graph.diagnostics.each do |diagnostic|
        next unless diagnostic.location.uri.to_s.start_with?(workspace)

        misses["diagnostic_#{diagnostic.rule}"] += 1
      end
      misses['engine_without_app'] = @engines_without_app if @engines_without_app.to_i.positive?
      { resolutions: resolutions, ancestry: ancestry, definitions: definitions, calls: calls, misses: misses }
    end

    # A singleton class is the class side of its attached class: a call on
    # Board.find is a call with the constant Board as receiver, and a
    # reference the engine resolved to <Board> names Board.
    def attached(declaration)
      declaration.is_a?(::Rubydex::SingletonClass) ? declaration.attached_class : declaration
    end

    def collect_ancestry(declaration, workspace, ancestry, misses)
      declaration.definitions.each do |definition|
        uri = definition.location.uri.to_s
        next unless uri.start_with?(workspace)

        file = uri.delete_prefix(workspace)
        line = definition.location.start_line + 1
        if definition.respond_to?(:superclass) && definition.superclass
          add_ancestry(ancestry, misses, declaration, 'inherits', definition.superclass, file, line, workspace)
        end
        next unless definition.respond_to?(:mixins)

        definition.mixins.each do |mixin|
          kind = MIXIN_KINDS[mixin.class.name]
          add_ancestry(ancestry, misses, declaration, kind, mixin.constant_reference, file, line, workspace) if kind
        end
      end
    end

    def add_ancestry(ancestry, misses, owner, kind, reference, file, line, workspace)
      target = reference.respond_to?(:declaration) ? reference.declaration : nil
      return misses['ancestry_unresolved'] += 1 if target.nil? || target.name.end_with?('>')

      ancestry << Ancestry.new(owner: owner.name, kind: kind, target: target.name, file: file, line: line,
                               in_workspace: in_workspace?(target, workspace))
    end

    def collect_definitions(declaration, workspace, definitions)
      declaration.members.each do |member|
        next unless member.is_a?(::Rubydex::Method)

        scope = declaration.is_a?(::Rubydex::SingletonClass) ? 'class' : 'instance'
        member.definitions.each do |definition|
          uri = definition.location.uri.to_s
          next unless uri.start_with?(workspace)

          definitions << Definition.new(owner: declaration.name.sub(SINGLETON_SUFFIX, ''),
                                        name: member.unqualified_name.to_s.delete_suffix('()'),
                                        scope: scope, visibility: member.visibility.to_s, file: uri.delete_prefix(workspace),
                                        line: definition.location.start_line + 1)
        end
      end
      return if declaration.is_a?(::Rubydex::SingletonClass)

      singleton = declaration.members.find { |member| member.is_a?(::Rubydex::SingletonClass) }
      collect_definitions(singleton, workspace, definitions) if singleton
    end

    def in_workspace?(declaration, workspace)
      declaration.definitions.any? { |definition| definition.location.uri.to_s.start_with?(workspace) }
    end

    def parser_edges_by_line(graph)
      graph.edges.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |edge, lines|
        next unless Graph::DEPENDENCY_EDGE_TYPES.include?(edge.type) && edge.confidence == :high

        lines[[edge.from_path, edge.location.line]] << edge
      end
    end

    def compare(graph, edges, target)
      return :written if edges.nil?

      resolved = edges.map { |edge| graph.resolve_edge_constant(edge) }
      defined = resolved.select { |name| graph.constants_named(name).any? }
      wanted = graph.resolve_constant_reference("::#{target}")
      return :already_resolved if defined.any? { |name| name == wanted || name.start_with?("#{wanted}::") }
      return :written if defined.size < resolved.size

      :disagreed
    end

    def declared_at?(graph, path, line, target)
      graph.constants_for_path(path).any? do |constant|
        constant.location.line == line && constant.name == graph.resolve_constant_reference("::#{target}")
      end
    end

    def owner_for(graph, path, line)
      enclosing = graph.constants_for_path(path).select do |constant|
        next false if constant.kind == :constant

        constant.location.line <= line && (constant.location.end_line || constant.location.line) >= line
      end
      innermost = enclosing.max_by { |constant| constant.location.line }
      innermost ? innermost.name : Pathname(path).relative_path_from(Pathname(graph.root)).to_s
    end
  end
end
