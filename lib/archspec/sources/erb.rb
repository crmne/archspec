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
        document = Herb.parse(source, prism_program: true).value
        # Herb omits the program payload for a completely empty file.
        parsed = source.empty? ? Prism.parse('', filepath: path) : Prism.load(source, document.prism_node)
        @prism = parsed.value
        @comments = parsed.comments.map { |comment| Comment.from_prism(comment) }
        collect_erb_comments(document, source.b)
        parsed
      end

      def collect_erb_comments(node, bytes)
        process_erb_comment(node.content, bytes) if node.is_a?(Herb::AST::ERBCommentNode)

        node.compact_child_nodes.each do |child|
          collect_erb_comments(child, bytes)
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
