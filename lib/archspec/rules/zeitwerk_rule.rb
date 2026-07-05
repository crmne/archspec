# frozen_string_literal: true

module ArchSpec
  module Rules
    # Backs ArchSpec::DSL::Context#verify_zeitwerk_names!. Flags files that do
    # not define the constant their path implies under Zeitwerk.
    class ZeitwerkNamingRule
      attr_reader :only

      # only: globs restricting which files are checked. Default is every file
      # ArchSpec can name, but lib autoloading is opt-in, so apps that require
      # lib manually scope this to app/.
      def initialize(only: nil)
        @only = Array(only).flatten.compact.map(&:to_s)
      end

      def id
        'zeitwerk.naming'
      end

      def evaluate(graph)
        scoped_paths = scoped_paths(graph)

        graph.files.values.filter_map do |file|
          next unless file.expected_constant
          next if scoped_paths && !scoped_paths.include?(file.path)

          defined = graph.constants_for_path(file.path).map(&:name)
          next if defined.include?(file.expected_constant)

          Diagnostic.new(
            rule: id,
            message: "#{file.relative_path} should define #{file.expected_constant}",
            location: SourceLocation.new(file.path, 1, 1),
            evidence: "defined constants: #{defined.empty? ? '(none)' : defined.join(', ')}"
          )
        end
      end

      private

      def scoped_paths(graph)
        return nil if only.empty?

        only.flat_map { |pattern| Dir.glob(File.absolute_path(pattern, graph.root)) }
            .map { |path| File.expand_path(path) }
            .to_set
      end
    end
  end
end
