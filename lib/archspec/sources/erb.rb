# frozen_string_literal: true

require 'herb'
require 'prism'
require_relative 'base'

module ArchSpec
  module Sources
    class Erb < Base
      attr_reader :comments, :prism

      def self.extensions
        %w[.erb]
      end

      private

      def parse_file
        source = File.read(path)
        Prism.parse(Herb.extract_ruby(source), filepath: path).tap do |parsed|
          @prism = parsed.value
          @comments = parsed.comments.map { |comment| Comment.from_prism(comment) }
          collect_erb_comments(source)
        end
      end

      def collect_erb_comments(source)
        bytes = source.b
        in_comment = false
        Herb.lex(source).value.each do |token|
          in_comment = true if token.type == 'TOKEN_ERB_START' && token.value == '<%#'
          next unless in_comment

          process_erb_comment(token, bytes) if token.type == 'TOKEN_ERB_CONTENT'

          in_comment = false if token.type == 'TOKEN_ERB_END'
        end
      end

      def process_erb_comment(token, bytes)
        start = token.location.start
        line_start = (bytes.rindex("\n", token.range.from - 1) || -1) + 1
        column = token.range.from - line_start
        token.value.each_line.with_index do |text, index|
          @comments << Comment.new(text, start.line + index, index.zero? ? column : 0)
        end
      end

    end
  end
end
