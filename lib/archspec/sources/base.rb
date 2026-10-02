# frozen_string_literal: true

require_relative 'comment'

module ArchSpec
  module Sources
    # Shared interface for source adapters. Normalizes the file path, parses
    # eagerly, and converts parser errors to ArchSpec source locations.
    # Subclasses provide supported extensions, a Prism program, and comments.
    class Base
      def self.extensions
        raise NotImplementedError
      end

      def self.rubydex_indexable?
        false
      end

      attr_reader :path

      def initialize(path)
        @path = File.expand_path(path)
        @result = parse_file
      end

      def comments
        raise NotImplementedError
      end

      def prism
        raise NotImplementedError
      end

      def parse_errors
        result.errors.map do |error|
          ParseError.new(error.message, SourceLocation.from_prism(path, error.location))
        end
      end

      private

      attr_reader :result

      def parse_file
        raise NotImplementedError
      end
    end
  end
end
