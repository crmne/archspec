# frozen_string_literal: true

require 'prism'
require_relative 'base'

module ArchSpec
  module Sources
    # Parses Ruby and Rake files with Prism and exposes their program and
    # comments. These sources also support semantic indexing with Rubydex.
    class Ruby < Base
      def self.extensions
        %w[.rb .rake]
      end

      def self.rubydex_indexable?
        true
      end

      def comments
        result.comments.map { |comment| Comment.from_prism(comment) }
      end

      def prism
        result.value
      end

      private

      def parse_file
        Prism.parse_file(path)
      end
    end
  end
end
