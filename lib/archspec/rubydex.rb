# frozen_string_literal: true

require 'fileutils'
require 'pathname'

require_relative 'error'
require_relative 'facts'
require_relative 'version'

module ArchSpec
  # Writes the facts file a second resolver can add to the parser's: constant
  # references Rubydex resolved to one declaration where the parser's lexical
  # lookup found nothing. Rubydex reads the workspace and its bundle, so the
  # targets it names may live in a gem; the determination says which side of
  # that boundary answered. Only <tt>archspec reflect --rubydex</tt> loads the
  # gem, and +check+ merges the file it writes like any other.
  module Rubydex
    extend self

    PRODUCER = 'archspec-rubydex'
    WORKSPACE = 'rubydex-workspace'
    GEM = 'rubydex-gem'
    SINGLETON_SUFFIX = /::<[^>]+>\z/

    Resolution = ValueObject.define(:file, :line, :target, :in_workspace)

    def run(graph, output:, root:)
      resolutions, misses = index(root)
      facts = facts_for(graph, resolutions, misses: misses, engine_version: ::Rubydex::VERSION)
      FileUtils.mkdir_p(File.dirname(output))
      Facts.write(output, commit: Facts.commit_for(root), dirty: Facts.dirty?(root), **facts)
      facts
    end

    # Turns Rubydex resolutions into references the parser did not already
    # have. Free of the gem so the comparison is tested with stand-ins: a
    # resolution is a file, a line, the resolved target and whether the
    # target is defined under the root.
    def facts_for(graph, resolutions, misses: {}, engine_version: nil)
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
        misses: counts.sort.to_h
      }
    end

    private

    def index(root)
      load_gem
      gemfile = File.join(root, 'Gemfile')
      raise Error, "no Gemfile at #{root}; reflect --rubydex indexes an application and its bundle" unless File.exist?(gemfile)

      bundle!(root)
      graph = Dir.chdir(root) do
        built = ::Rubydex::Graph.new
        built.index_workspace
        built.resolve
        built
      end
      collect(graph, File.expand_path(root))
    rescue StandardError => e
      raise e if e.is_a?(Error)

      raise Error, "reflect --rubydex could not index #{root}: #{e.message.lines.first&.strip}"
    end

    def bundle!(root)
      require 'bundler'
      locked = Dir.chdir(root) { ::Bundler.locked_gems }
      return if locked

      raise Error, "no Gemfile.lock at #{root}; reflect --rubydex indexes the locked bundle, never the workspace alone"
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

      graph.constant_references.each do |reference|
        uri = reference.location.uri.to_s
        next unless uri.start_with?(workspace)

        unless reference.is_a?(::Rubydex::ResolvedConstantReference)
          misses['unresolved'] += 1
          next
        end

        declaration = reference.declaration
        next if declaration.nil? || declaration.name.end_with?('>')

        resolutions << Resolution.new(
          file: uri.delete_prefix(workspace),
          line: reference.location.start_line + 1,
          target: declaration.name.sub(SINGLETON_SUFFIX, ''),
          in_workspace: declaration.definitions.any? { |definition| definition.location.uri.to_s.start_with?(workspace) }
        )
      end

      misses['diagnostic'] = graph.diagnostics.count { |diagnostic| diagnostic.location.uri.to_s.start_with?(workspace) }
      [resolutions, misses]
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
