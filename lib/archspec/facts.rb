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
    LIST_KEYS = %w[references methods mixins exposures gaps receivers].freeze

    def snapshot(graph, excluding: 'archspec_facts')
      excluded = File.expand_path(excluding, graph.root)
      inputs = Dir.glob(File.join(graph.root, 'config/**/*.{rb,yml,yaml}')) +
               Dir.glob(File.join(graph.root, '{Gemfile,Gemfile.lock,*.gemspec,.ruby-version}'))
      (graph.files.keys + inputs).select { |path| File.file?(path) }
        .reject { |path| path == excluded || path.start_with?("#{excluded}/") }
        .uniq.sort.to_h do |path|
          [Pathname(path).relative_path_from(Pathname(graph.root)).to_s, Digest::SHA256.file(path).hexdigest]
        end
    end

    def load_into(graph, directory)
      paths = Dir.glob(File.join(File.expand_path(directory, graph.root), '*.yml')).sort
      raise Error, "no facts found in #{directory}; run `archspec reflect` or your facts producer" if paths.empty?

      current = snapshot(graph, excluding: directory)
      batches = paths.map do |path|
        document = Document.new(graph, YAML.safe_load_file(path, permitted_classes: [], aliases: false), path)
        document.validate_snapshot(current)
        document.compile
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
        File.rename(file.path, path)
      end
    rescue SystemCallError => error
      raise Error, "could not write facts #{path}: #{error.message}"
    end
  end
end

require_relative 'facts/application'
require_relative 'facts/document'
require_relative 'facts/builder'
