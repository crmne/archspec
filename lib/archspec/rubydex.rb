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
    Definition = ValueObject.define(:owner, :name, :scope, :visibility, :file, :line)
    Call = ValueObject.define(:file, :line, :method, :receiver, :in_workspace)
    MIXIN_KINDS = { 'Rubydex::Include' => 'includes', 'Rubydex::Prepend' => 'prepends',
                    'Rubydex::Extend' => 'extends' }.freeze

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
                        ancestry: found[:ancestry], definitions: found[:definitions], calls: found[:calls])
      [facts, found, cache, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
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
      sources = ::Bundler::LockfileParser.new(File.read(lockfile)).sources.grep(::Bundler::Source::Path)
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
          column: reference.location.start_column + 1,
          target: declaration.name.sub(SINGLETON_SCOPE, ''),
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
                          method: reference.name.to_s, receiver: receiver.name.sub(SINGLETON_SCOPE, ''),
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

          definitions << Definition.new(owner: declaration.name.sub(SINGLETON_SCOPE, ''),
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
