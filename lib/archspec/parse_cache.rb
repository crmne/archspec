# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'prism'

module ArchSpec
  # Remembers what the visitor extracted from a file, keyed by the file's
  # content and by everything that shapes extraction: the gem version and
  # the parser version. A hit replays the facts into the graph in the order
  # the visitor would have added them; a miss parses as always and records
  # the result. Entries are plain arrays, hashes, strings and symbols written
  # with the standard library's Marshal, and an entry that fails to load is
  # a miss, never an error.
  class ParseCache
    FORMAT = 1

    def initialize(directory, root:)
      @directory = File.expand_path(directory, root)
      @settings = Digest::SHA256.hexdigest([FORMAT, ArchSpec::VERSION, Prism::VERSION].join("\0"))[0, 16]
    end

    attr_reader :directory

    def fetch(path)
      entry_path = entry_path_for(path)
      return unless File.exist?(entry_path)

      entry = Marshal.load(File.binread(entry_path))
      entry.is_a?(Hash) && entry[:format] == FORMAT ? entry : nil
    rescue ArgumentError, TypeError, SystemCallError
      nil
    end

    def store(path, entry)
      FileUtils.mkdir_p(directory)
      ignore = File.join(directory, '.gitignore')
      File.write(ignore, "*\n") unless File.exist?(ignore)
      File.binwrite(entry_path_for(path), Marshal.dump(entry))
    rescue SystemCallError
      nil
    end

    # The facts the visitor added for +path+: the file record plus every
    # constant and edge appended since the counts taken before the visit.
    def self.record(graph, path, constants_from:, edges_from:)
      file = graph.files.fetch(path)
      {
        format: FORMAT,
        parse_errors: file.parse_errors.map { |error| [error.message, location_of(error.location)] },
        suppressions: file.suppressions.map do |suppression|
          [suppression.rule, suppression.start_line, suppression.end_line, suppression.reason]
        end,
        constants: graph.constants.drop(constants_from).map { |constant| constant_record(constant) },
        edges: graph.edges.drop(edges_from).map { |edge| edge_record(edge) }
      }
    end

    def self.replay(graph, path, entry)
      graph.add_file(
        path: path,
        parse_errors: entry.fetch(:parse_errors).map do |message, location|
          ParseError.new(message, location_at(path, location))
        end,
        suppressions: entry.fetch(:suppressions).map do |rule, start_line, end_line, reason|
          Suppression.new(rule, start_line, end_line, reason)
        end
      )
      entry.fetch(:constants).each { |record| replay_constant(graph, path, record) }
      entry.fetch(:edges).each do |type, from_constant, to, location, confidence, receiver, lexical_nesting|
        graph.add_edge(type: type, from_path: path, from_constant: from_constant, to: to,
                       location: location_at(path, location), confidence: confidence, receiver: receiver,
                       lexical_nesting: lexical_nesting)
      end
    end

    class << self
      private

      def constant_record(constant)
        {
          name: constant.name,
          kind: constant.kind,
          location: location_of(constant.location),
          nesting: constant.nesting.to_a,
          superclass: constant.superclass,
          abstract: constant.abstract?,
          methods: constant.method_definitions.map do |definition|
            [definition.name, definition.scope, location_of(definition.location), definition.visibility]
          end,
          mixins: constant.mixins.transform_values(&:to_a),
          associations: constant.associations.map do |declaration|
            [declaration.name, declaration.macro, declaration.class_name, declaration.through, declaration.source,
             declaration.source_type, declaration.polymorphic, location_of(declaration.location),
             declaration.nesting.to_a]
          end
        }
      end

      def edge_record(edge)
        [edge.type, edge.from_constant, edge.to, location_of(edge.location), edge.confidence, edge.receiver,
         edge.lexical_nesting&.to_a]
      end

      def replay_constant(graph, path, record)
        constant = graph.add_constant(name: record.fetch(:name), kind: record.fetch(:kind), path: path,
                                      location: location_at(path, record.fetch(:location)),
                                      nesting: record.fetch(:nesting))
        constant.superclass = record.fetch(:superclass)
        constant.abstract = record.fetch(:abstract)
        record.fetch(:methods).each do |name, scope, location, visibility|
          at = location_at(path, location)
          if scope == :class
            constant.add_class_method(name, location: at, visibility: visibility)
          else
            constant.add_instance_method(name, location: at, visibility: visibility)
          end
        end
        record.fetch(:mixins).each { |kind, names| names.each { |name| constant.add_mixin(kind, name) } }
        record.fetch(:associations).each do |name, macro, class_name, through, source, source_type, polymorphic,
                                            location, nesting|
          constant.add_association(AssociationDeclaration.new(
                                     owner: constant.name, name: name, macro: macro, class_name: class_name,
                                     through: through, source: source, source_type: source_type,
                                     polymorphic: polymorphic, location: location_at(path, location),
                                     nesting: nesting
                                   ))
        end
      end

      def location_of(location)
        [location.line, location.column, location.end_line, location.end_column]
      end

      def location_at(path, values)
        line, column, end_line, end_column = values
        SourceLocation.new(path, line, column, end_line, end_column)
      end
    end

    private

    def entry_path_for(path)
      File.join(directory, "#{Digest::SHA256.file(path).hexdigest}-#{@settings}.marshal")
    end
  end
end
