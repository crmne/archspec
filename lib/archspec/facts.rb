# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'tempfile'
require 'yaml'

module ArchSpec
  # Shared semantic facts and versioned snapshots. Static framework passes and
  # explicit runtime producers use Builder; checks import data without booting.
  module Facts
    extend self

    VERSION = 2
    LIST_KEYS = %w[references methods mixins exposures gaps receivers resolves].freeze
    # Files outside the analyzed source that can change what any producer
    # observes. A change to one of them invalidates a whole document.
    DEFAULT_INPUTS = ['config/**/*.{rb,yml,yaml}', 'Gemfile', 'Gemfile.lock', '*.gemspec', '.ruby-version'].freeze
    STALE_RULE = 'facts.stale'

    # The exact input map of a version 1 document: every analyzed file plus the
    # default inputs.
    def snapshot(graph, excluding: 'archspec_facts')
      paths = graph.files.keys + input_files(graph, DEFAULT_INPUTS, excluding: excluding)
      digests(graph, paths.reject { |path| excluded?(graph, path, excluding) })
    end

    # A version 2 fingerprint: the producer's global inputs, the analyzed files
    # its source patterns cover, and every file the facts cite.
    def fingerprint(graph, inputs:, sources:, cited:, excluding:)
      paths = input_files(graph, inputs, excluding: excluding) + source_files(graph, sources) +
              cited.select { |path| File.file?(path) }
      digests(graph, paths)
    end

    def input_files(graph, patterns, excluding:)
      patterns.flat_map { |pattern| Dir.glob(File.join(graph.root, pattern)) }
              .select { |path| File.file?(path) }.map { |path| File.expand_path(path) }
              .reject { |path| excluded?(graph, path, excluding) }
    end

    # Source patterns match analyzed files only, so covering a directory never
    # walks the file system.
    def source_files(graph, patterns)
      return [] if patterns.empty?

      graph.files.values.select do |file|
        patterns.any? { |pattern| File.fnmatch?(pattern, file.relative_path, File::FNM_PATHNAME | File::FNM_EXTGLOB) }
      end.map(&:path)
    end

    def digest(path)
      Digest::SHA256.file(path).hexdigest if File.file?(path)
    end

    # Loads every document in the directory. Stale documents and the facts of
    # stale files are skipped and reported as diagnostics; everything else is
    # validated before any of it is applied.
    def load_into(graph, directory)
      paths = Dir.glob(File.join(File.expand_path(directory, graph.root), '*.yml')).sort
      raise Error, "no facts found in #{directory}; run `archspec reflect` or your facts producer" if paths.empty?

      batches = paths.filter_map do |path|
        document = Document.new(graph, YAML.safe_load_file(path, permitted_classes: [], aliases: false), path)
        document.compile_fresh(excluding: directory)
      end
      Application.apply(graph, batches)
    rescue Psych::Exception, SystemCallError => error
      raise Error, "could not load facts: #{error.message}"
    end

    def write(path, document)
      FileUtils.mkdir_p(File.dirname(path))
      Tempfile.create(['.archspec-facts-', '.yml'], File.dirname(path)) do |file|
        file.write(document.to_yaml)
        file.flush
        file.close
        File.chmod(0o666 & ~File.umask, file.path)
        File.rename(file.path, path)
      end
    rescue SystemCallError => error
      raise Error, "could not write facts #{path}: #{error.message}"
    end

    private

    def excluded?(graph, path, excluding)
      excluded = File.expand_path(excluding, graph.root)
      path == excluded || path.start_with?("#{excluded}/")
    end

    def digests(graph, paths)
      root = Pathname(graph.root)
      paths.uniq.sort.to_h { |path| [Pathname(path).relative_path_from(root).to_s, digest(path)] }
    end
  end
end

require_relative 'facts/application'
require_relative 'facts/document'
require_relative 'facts/builder'
