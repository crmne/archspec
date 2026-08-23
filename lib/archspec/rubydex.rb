# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'pathname'
require 'set'

require_relative 'error'
require_relative 'facts'
require_relative 'snapshot'
require_relative 'version'

module ArchSpec
  # Writes the facts file a second resolver can add to the parser's: constant
  # references Rubydex resolved to one declaration where the parser's lexical
  # lookup found nothing. Rubydex reads the workspace and its bundle, so the
  # targets it names may live in a gem; the determination says which side of
  # that boundary answered. The same discipline covers what else Rubydex
  # states about the workspace: a superclass or mixin the parser has none
  # for, a method it did not see defined, and a call whose receiver Rubydex
  # resolved to a constant. The gem loads only from
  # <tt>archspec reflect --rubydex</tt> or a check whose architecture file
  # declares <tt>resolver :rubydex</tt>; the latter merges the same facts in
  # memory and sets every answer beside the parser's.
  module Rubydex
    extend self

    PRODUCER = 'archspec-rubydex'
    INDEX_FORMAT = 1
    RESOLVER_LABEL = "#{PRODUCER} (resolver)"
    WORKSPACE = 'rubydex-workspace'
    GEM = 'rubydex-gem'
    SINGLETON_SCOPE = /::<[^>]+>/

    Resolution = ValueObject.define(:file, :line, :column, :target, :in_workspace)
    Ancestry = ValueObject.define(:owner, :kind, :target, :file, :line, :in_workspace)
    Definition = ValueObject.define(:owner, :name, :scope, :visibility, :file, :line, :signature)
    Call = ValueObject.define(:file, :line, :method, :receiver, :scope, :in_workspace)
    External = ValueObject.define(:name, :kind, :origin, :instance_methods, :class_methods)
    Ancestors = ValueObject.define(:owner, :instance, :class_side, :in_workspace)
    Alias = ValueObject.define(:owner, :kind, :name, :target, :file, :line)
    Diagnostic = ValueObject.define(:rule, :file, :line)
    MIXIN_KINDS = { 'Rubydex::Include' => 'includes', 'Rubydex::Prepend' => 'prepends',
                    'Rubydex::Extend' => 'extends' }.freeze
    CORE = 'core'
    DYNAMIC_ANCESTOR = 'DynamicAncestor'

    def run(graph, output:, root:, cache_directory: nil)
      facts, = resolve(graph, root: root, cache_directory: cache_directory)
      Facts.write_to(output, root: root, **facts)
      facts
    end

    # The facts a check merges when the resolver is declared: the same file
    # reflect writes, built in memory, with every answer Rubydex gave recorded
    # on the graph so each parser edge can be read beside it.
    def facts_file(graph, root:, cache_directory: nil)
      facts, found, cache, seconds = resolve(graph, root: root, cache_directory: cache_directory)
      graph.record_resolver('rubydex', answers_by_reference(graph, found[:resolutions]), cache: cache, seconds: seconds,
                                       resolver_only: facts[:references].size)
      Facts.built(label: RESOLVER_LABEL, **facts)
    end

    # Indexes the workspace and its bundle, or reads the index kept from an
    # identical tree and bundle, and turns the answers into facts the parser
    # did not already have.
    def resolve(graph, root:, cache_directory: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      load_gem
      gemfile = File.join(root, 'Gemfile')
      raise Error, "no Gemfile at #{root}; reflect --rubydex indexes an application and its bundle" unless File.exist?(gemfile)

      lockfile = bundle!(root)
      cached = cache_directory && cache_path(cache_directory, root, lockfile, graph)
      found = cached ? read_index(cached) : nil
      cache = found ? 'hit' : 'miss'
      found ||= index(root).tap { |indexed| write_index(cached, indexed) if cached }
      facts = facts_for(graph, found[:resolutions], misses: found[:misses], engine_version: found[:engine_version],
                        ancestry: found[:ancestry], definitions: found[:definitions], calls: found[:calls],
                        externals: found.fetch(:externals, []), ancestors: found.fetch(:ancestors, []),
                        aliases: found.fetch(:aliases, []), diagnostics: found.fetch(:diagnostics, []))
      [facts, found, cache, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
    end

    # Turns Rubydex resolutions into references the parser did not already
    # have. Free of the gem so the comparison is tested with stand-ins: a
    # resolution is a file, a line, the resolved target and whether the
    # target is defined under the root.
    def facts_for(graph, resolutions, misses: {}, engine_version: nil, ancestry: [], definitions: [], calls: [],
                  externals: [], ancestors: [], aliases: [], diagnostics: [])
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
        externals: external_facts(graph, externals, counts),
        ancestors: ancestors_facts(graph, ancestors, counts),
        aliases: alias_facts(graph, aliases, counts),
        diagnostics: diagnostic_facts(graph, diagnostics),
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

    # A definition the parser already has is written when the engine knows
    # what it takes and the parser recorded no signature, which is how a
    # macro-defined method gets one; otherwise it is counted.
    def definition_facts(graph, entries, counts)
      entries.filter_map do |entry|
        owner = owner_node(graph, entry.owner, entry.file)
        unless owner
          counts['definition_outside_source'] += 1
          next
        end

        known = entry.scope == 'class' ? owner.class_methods : owner.instance_methods
        if known.include?(entry.name.to_sym)
          described = owner.definition_of(entry.name, entry.scope.to_sym)
          counts['definition_already_resolved'] += 1
          next unless described && described.signature.nil? && entry.signature
        end

        FactsDefinition.new(owner: owner.name, name: entry.name, scope: entry.scope, visibility: entry.visibility,
                            file: entry.file, line: entry.line, determination: WORKSPACE, signature: entry.signature)
      end.uniq
    end

    # Declarations outside the workspace the engine resolved a workspace
    # reference, ancestor or receiver to, each with the methods the engine
    # lists, so a component can own them by name and a protocol can read
    # them; nothing from the bundle that nothing in the workspace reaches.
    def external_facts(graph, entries, counts)
      entries.filter_map do |entry|
        if graph.constants_named(entry.name).any? { |node| !node.external? }
          counts['external_defined_in_workspace'] += 1
          next
        end

        FactsExternal.new(name: entry.name, kind: entry.kind, origin: entry.origin,
                          instance_methods: entry.instance_methods.map(&:to_sym), class_methods: entry.class_methods.map(&:to_sym))
      end.uniq(&:name)
    end

    def ancestors_facts(graph, entries, counts)
      entries.filter_map do |entry|
        if graph.constants_named(entry.owner).none? { |node| !node.external? }
          counts['ancestors_outside_source'] += 1
          next
        end

        FactsAncestors.new(owner: entry.owner, instance: entry.instance, class_side: entry.class_side,
                           determination: entry.in_workspace ? WORKSPACE : GEM)
      end.uniq(&:owner)
    end

    def alias_facts(graph, entries, counts)
      entries.filter_map do |entry|
        unless graph.files.key?(File.expand_path(entry.file, graph.root))
          counts['alias_outside_source'] += 1
          next
        end

        FactsAlias.new(owner: entry.owner, kind: entry.kind, name: entry.name, target: entry.target, file: entry.file,
                       line: entry.line, determination: WORKSPACE)
      end.uniq
    end

    def diagnostic_facts(graph, entries)
      entries.filter_map do |entry|
        next unless graph.files.key?(File.expand_path(entry.file, graph.root))

        FactsDiagnostic.new(rule: entry.rule, file: entry.file, line: entry.line)
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
                      method: entry.method, receiver: entry.receiver, scope: entry.scope,
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
      graph = Dir.chdir(root) { build_index }
      collect(graph, File.expand_path(root)).merge(engine_version: ::Rubydex::VERSION)
    end

    def bundle!(root)
      lockfile = File.join(root, 'Gemfile.lock')
      return lockfile if File.readable?(lockfile)

      raise Error, "no Gemfile.lock at #{root}; reflect --rubydex indexes the locked bundle, never the workspace alone"
    end

    # One index per tree and bundle: the key is the lockfile's content, the
    # two versions, the parsed set with its contents, and the content of any
    # gem the lockfile points at a path rather than a version, which changes
    # without the lockfile moving. Rubydex resolves across files, so a source
    # edit indexes again; the warm path is an unchanged tree.
    def cache_path(directory, root, lockfile, graph)
      key = Digest::SHA256.hexdigest([File.read(lockfile), ::Rubydex::VERSION, VERSION,
                                      Snapshot.parsed_set_digest(graph), path_gems_digest(root, lockfile)].join("\0"))[0, 24]
      File.join(File.expand_path(directory, root), "rubydex-#{key}.marshal")
    end

    def path_gems_digest(root, lockfile)
      require 'bundler'
      parser = ::Bundler::LockfileParser.new(File.read(lockfile))
      sources = parser.sources.grep(::Bundler::Source::Path)
      entries = sources.flat_map do |source|
        Dir.glob(File.join(File.expand_path(source.path.to_s, root), '**', '*.rb')).sort.map do |file|
          "#{file}\0#{Digest::SHA256.file(file).hexdigest}"
        end
      end
      Digest::SHA256.hexdigest(entries.join("\n"))
    rescue ::Bundler::BundlerError, SystemCallError
      ''
    end

    # One payload per key; an index from another tree or bundle under the same
    # directory is removed when a new one is written, so the directory holds
    # the current index and nothing else.
    def write_index(path, found)
      FileUtils.mkdir_p(File.dirname(path))
      ignore = File.join(File.dirname(File.dirname(path)), '.gitignore')
      File.write(ignore, "*\n") unless File.exist?(ignore)
      Dir.glob(File.join(File.dirname(path), 'rubydex-*.marshal')).each { |stale| File.delete(stale) unless stale == path }
      File.binwrite(path, Marshal.dump(found.merge(index_format: INDEX_FORMAT)))
    end

    def read_index(path)
      return unless File.exist?(path)

      found = Marshal.load(File.binread(path))
      found if found.is_a?(Hash) && found[:index_format] == INDEX_FORMAT && found.key?(:resolutions)
    rescue ArgumentError, TypeError, SystemCallError
      nil
    end

    # Every answer Rubydex gave for a reference in a line the parser read, by
    # file, line and column, apart from the name the line declares and
    # +self+, which are no reference at all.
    def answers_by_reference(graph, resolutions)
      resolutions.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |resolution, answers|
        path = File.expand_path(resolution.file, graph.root)
        next unless graph.files.key?(path)
        next if declared_at?(graph, path, resolution.line, resolution.target)
        next if owner_for(graph, path, resolution.line) == graph.resolve_constant_reference("::#{resolution.target}")

        answers[[path, resolution.line]] << [resolution.column, resolution.target]
      end
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
      origins = origins_of(graph.workspace_paths)
      misses = Hash.new(0)
      resolutions = []
      ancestry = []
      definitions = []
      calls = []
      reached = {}

      graph.constant_references.each do |reference|
        uri = reference.location.uri.to_s
        next unless uri.start_with?(workspace)

        unless reference.is_a?(::Rubydex::ResolvedConstantReference)
          misses['unresolved'] += 1
          next
        end

        declaration = attached(reference.declaration)
        next if declaration.nil?

        in_workspace = in_workspace?(declaration, workspace)
        reach(reached, declaration, workspace) unless in_workspace
        resolutions << Resolution.new(
          file: uri.delete_prefix(workspace),
          line: reference.location.start_line + 1,
          column: reference.location.start_column + 1,
          target: declaration.name.sub(SINGLETON_SCOPE, ''),
          in_workspace: in_workspace
        )
      end

      dynamic = dynamic_spans(graph, workspace)
      ancestors = []
      aliases = []
      graph.declarations.each do |declaration|
        aliases.concat(constant_alias_of(declaration, workspace)) if declaration.is_a?(::Rubydex::ConstantAlias)
        next unless declaration.is_a?(::Rubydex::Namespace) && !declaration.is_a?(::Rubydex::SingletonClass)

        collect_ancestry(declaration, workspace, ancestry, misses, reached)
        collect_definitions(declaration, workspace, definitions, aliases, misses)
        next unless in_workspace?(declaration, workspace)

        if dynamic_chain?(declaration, dynamic, workspace)
          misses['ancestors_dynamic'] += 1
          next
        end
        ancestors << chain_of(declaration, reached, workspace)
      end

      graph.method_references.each do |reference|
        uri = reference.location.uri.to_s
        next unless uri.start_with?(workspace)

        receiver = reference.receiver
        next unless receiver.is_a?(::Rubydex::Namespace)

        scope = receiver.is_a?(::Rubydex::SingletonClass) ? 'class' : 'instance'
        receiver = attached(receiver)
        in_workspace = in_workspace?(receiver, workspace)
        reach(reached, receiver, workspace) unless in_workspace
        calls << Call.new(file: uri.delete_prefix(workspace), line: reference.location.start_line + 1,
                          method: reference.name.to_s.delete_suffix('()'), receiver: receiver.name.sub(SINGLETON_SCOPE, ''),
                          scope: scope, in_workspace: in_workspace)
      end

      diagnostics = []
      graph.diagnostics.each do |diagnostic|
        uri = diagnostic.location.uri.to_s
        next unless uri.start_with?(workspace)

        rule = diagnostic.rule.to_s.split('::').last
        misses["diagnostic_#{rule}"] += 1
        diagnostics << Diagnostic.new(rule: rule, file: uri.delete_prefix(workspace), line: diagnostic.location.start_line + 1)
      end
      misses['engine_without_app'] = @engines_without_app if @engines_without_app.to_i.positive?
      { resolutions: resolutions, ancestry: ancestry, definitions: definitions, calls: calls, misses: misses,
        externals: externals_of(reached, origins, workspace), ancestors: ancestors, aliases: aliases, diagnostics: diagnostics }
    end

    # The gem each indexed path belongs to, read off the paths the engine
    # listed: the workspace first, then each locked gem's require path, then
    # the core library the engine ships as signatures.
    def origins_of(paths)
      paths.drop(1).to_h do |path|
        gem_dir = path.split('/gems/').last.to_s.split('/').first.to_s
        origin = gem_dir.start_with?('rbs-') && path.end_with?('/core') ? CORE : gem_dir.sub(/-[^-]+\z/, '')
        [path, origin]
      end
    end

    # A declaration outside the workspace that something in it resolved to,
    # and every ancestor of it, held by name once.
    def reach(reached, declaration, workspace, depth = 0)
      declaration = attached(declaration)
      return if declaration.nil? || !declaration.is_a?(::Rubydex::Namespace) && !declaration.is_a?(::Rubydex::Constant)
      return if reached.key?(declaration.name) || in_workspace?(declaration, workspace)

      reached[declaration.name] = declaration
      return unless declaration.is_a?(::Rubydex::Namespace) && depth < 64

      declaration.ancestors.each { |ancestor| reach(reached, ancestor, workspace, depth + 1) }
      singleton = declaration.singleton_class
      singleton&.ancestors&.each { |ancestor| reach(reached, ancestor, workspace, depth + 1) }
    end

    def externals_of(reached, origins, workspace)
      reached.values.filter_map do |declaration|
        name = declaration.name.sub(SINGLETON_SCOPE, '')
        next if name.include?('<')

        kind = case declaration
               when ::Rubydex::Class then 'class'
               when ::Rubydex::Module then 'module'
               else 'constant'
               end
        External.new(name: name, kind: kind, origin: origin_of(declaration, origins),
                     instance_methods: method_names(declaration), class_methods: method_names(declaration.respond_to?(:singleton_class) ? declaration.singleton_class : nil))
      end.sort_by(&:name)
    end

    def origin_of(declaration, origins)
      paths = declaration.definitions.map { |definition| definition.location.uri.to_s.delete_prefix('file://') }
      found = origins.find { |path, _origin| paths.any? { |file| file.start_with?("#{path}/") } }
      found ? found.last : CORE
    end

    def method_names(namespace)
      return [] unless namespace.respond_to?(:members)

      namespace.members.filter_map { |member| member.unqualified_name.to_s.delete_suffix('()') if member.is_a?(::Rubydex::Method) }.sort
    end

    # The engine's linearised chain for a workspace namespace, both sides:
    # the instance ancestors by name, and the singleton's ancestors each read
    # on the class side (a singleton class, as its attached class's class
    # methods) or the instance side (a module the class extends).
    def chain_of(declaration, reached, workspace)
      instance = declaration.ancestors.map { |ancestor| ancestor.name }
      class_side = Array(declaration.singleton_class&.ancestors).map do |ancestor|
        if ancestor.is_a?(::Rubydex::SingletonClass)
          [attached(ancestor).name, 'class']
        else
          [ancestor.name, 'instance']
        end
      end
      (declaration.ancestors + Array(declaration.singleton_class&.ancestors)).each { |ancestor| reach(reached, ancestor, workspace) }
      Ancestors.new(owner: declaration.name, instance: instance, class_side: class_side, in_workspace: true)
    end

    def dynamic_spans(graph, workspace)
      graph.diagnostics.filter_map do |diagnostic|
        next unless diagnostic.rule.to_s.end_with?(DYNAMIC_ANCESTOR)

        uri = diagnostic.location.uri.to_s
        [uri, diagnostic.location.start_line] if uri.start_with?(workspace)
      end
    end

    def dynamic_chain?(declaration, dynamic, workspace)
      declaration.definitions.any? do |definition|
        uri = definition.location.uri.to_s
        next false unless uri.start_with?(workspace)

        dynamic.any? do |file, line|
          file == uri && line >= definition.location.start_line && line <= definition.location.end_line
        end
      end || declaration.ancestors.any? { |ancestor| ancestor.name.include?('<') && !ancestor.is_a?(::Rubydex::SingletonClass) }
    end

    def constant_alias_of(declaration, workspace)
      declaration.definitions.filter_map do |definition|
        uri = definition.location.uri.to_s
        next unless uri.start_with?(workspace)

        target = declaration.target
        next unless target.respond_to?(:name)

        Alias.new(owner: declaration.owner&.name.to_s.sub(SINGLETON_SCOPE, '').then { |owner| owner.empty? ? 'Object' : owner },
                  kind: 'constant', name: declaration.name, target: target.name.sub(SINGLETON_SCOPE, ''),
                  file: uri.delete_prefix(workspace), line: definition.location.start_line + 1)
      end
    end

    # A singleton class is the class side of its attached class: a call on
    # Board.find is a call with the constant Board as receiver, and a
    # reference the engine resolved to <Board> names Board.
    def attached(declaration)
      declaration.is_a?(::Rubydex::SingletonClass) ? declaration.attached_class : declaration
    end

    def collect_ancestry(declaration, workspace, ancestry, misses, reached)
      declaration.definitions.each do |definition|
        uri = definition.location.uri.to_s
        next unless uri.start_with?(workspace)

        file = uri.delete_prefix(workspace)
        line = definition.location.start_line + 1
        if definition.respond_to?(:superclass) && definition.superclass
          add_ancestry(ancestry, misses, declaration, 'inherits', definition.superclass, file, line, workspace, reached)
        end
        next unless definition.respond_to?(:mixins)

        definition.mixins.each do |mixin|
          kind = MIXIN_KINDS[mixin.class.name]
          add_ancestry(ancestry, misses, declaration, kind, mixin.constant_reference, file, line, workspace, reached) if kind
        end
      end
    end

    def add_ancestry(ancestry, misses, owner, kind, reference, file, line, workspace, reached)
      target = reference.respond_to?(:declaration) ? reference.declaration : nil
      return misses['ancestry_unresolved'] += 1 if target.nil? || target.name.end_with?('>')

      in_workspace = in_workspace?(target, workspace)
      reach(reached, target, workspace) unless in_workspace
      ancestry << Ancestry.new(owner: owner.name, kind: kind, target: target.name, file: file, line: line,
                               in_workspace: in_workspace)
    end

    # An alias whose chain the engine cannot close is no target at all; it is
    # counted and the definition keeps its name.
    def alias_target(definition, misses)
      target = definition.target
      return nil unless target.respond_to?(:unqualified_name)

      target.unqualified_name.to_s.delete_suffix('()')
    rescue ::Rubydex::Error
      misses['alias_cycle'] += 1
      nil
    end

    def collect_definitions(declaration, workspace, definitions, aliases, misses)
      owner = declaration.name.sub(SINGLETON_SCOPE, '')
      declaration.members.each do |member|
        next unless member.is_a?(::Rubydex::Method)

        scope = declaration.is_a?(::Rubydex::SingletonClass) ? 'class' : 'instance'
        name = member.unqualified_name.to_s.delete_suffix('()')
        member.definitions.each do |definition|
          uri = definition.location.uri.to_s
          next unless uri.start_with?(workspace)

          file = uri.delete_prefix(workspace)
          line = definition.location.start_line + 1
          if definition.is_a?(::Rubydex::MethodAliasDefinition)
            target = alias_target(definition, misses)
            aliases << Alias.new(owner: owner, kind: 'method', name: name, target: target, file: file, line: line) if target
          end
          definitions << Definition.new(owner: owner, name: name, scope: scope, visibility: member.visibility.to_s,
                                        file: file, line: line, signature: signature_of(definition))
        end
      end
      return if declaration.is_a?(::Rubydex::SingletonClass)

      singleton = declaration.members.find { |member| member.is_a?(::Rubydex::SingletonClass) }
      collect_definitions(singleton, workspace, definitions, aliases, misses) if singleton
    end

    # What a definition takes, read off the engine's first signature for it;
    # a forward parameter counts as rest, rest keywords and a block at once.
    def signature_of(definition)
      return nil unless definition.respond_to?(:signatures)

      signature = definition.signatures.first
      return nil unless signature

      parameters = signature.parameters
      forward = parameters.any?(::Rubydex::Signature::ForwardParameter)
      Signature.new(
        parameters.count(::Rubydex::Signature::PositionalParameter) + parameters.count(::Rubydex::Signature::PostParameter),
        parameters.count(::Rubydex::Signature::OptionalPositionalParameter),
        parameters.any?(::Rubydex::Signature::RestPositionalParameter) || forward,
        parameters.select { |parameter| parameter.is_a?(::Rubydex::Signature::KeywordParameter) }.map { |parameter| parameter.name.to_sym },
        parameters.select { |parameter| parameter.is_a?(::Rubydex::Signature::OptionalKeywordParameter) }.map { |parameter| parameter.name.to_sym },
        parameters.any?(::Rubydex::Signature::RestKeywordParameter) || forward,
        parameters.any?(::Rubydex::Signature::BlockParameter) || forward
      )
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

    # The name a line declares, and every namespace on the way to it: writing
    # <tt>module Billing::Invoices</tt> names Billing without depending on it.
    def declared_at?(graph, path, line, target)
      wanted = graph.resolve_constant_reference("::#{target}")
      graph.constants_for_path(path).any? do |constant|
        constant.location.line == line &&
          (constant.name == wanted || constant.name.start_with?("#{wanted}::"))
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
