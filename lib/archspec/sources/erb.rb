# frozen_string_literal: true

require 'herb'
require 'prism'
require_relative 'base'

module ArchSpec
  module Sources
    # Parses ERB templates with Herb, exposing a complete Prism program and
    # suppression comments at their original template positions. ERB sources
    # contribute syntax facts without being indexed by Rubydex.
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
        collect_comments!(source, document, parsed)
        parsed
      end

      def collect_comments!(source, document, parsed)
        bytes = source.b
        @comments = []
        # Work around a Herb bug: Prism comment ranges extend past ERB closing
        # tags to the end of the physical line. This Collects tag boundaries and
        # clamps comments; Intention is to remove once it's fixed upstream.
        ruby_ranges = []
        collect_erb_comments(document, bytes, ruby_ranges)
        ruby_ranges.sort_by!(&:from)
        parsed.comments.each do |comment|
          location = comment.location
          range = ruby_ranges.bsearch { |candidate| candidate.to > location.start_offset }
          finish = location.end_offset
          finish = [finish, range.to].min if range && range.from <= location.start_offset
          @comments << Comment.new(source.byteslice(location.start_offset...finish), location.start_line, location.start_column)
        end
        @comments.uniq! { |comment| [comment.line, comment.column] }
      end

      def collect_erb_comments(node, bytes, ruby_ranges)
        if node.is_a?(Herb::AST::ERBCommentNode)
          process_erb_comment(node.content, bytes)
        elsif node.respond_to?(:tag_opening) && node.tag_opening&.value&.start_with?('<%') &&
              node.respond_to?(:content) && node.content
          ruby_ranges << node.content.range
          # Work around a Herb bug: single-line comment-only Ruby tags are absent
          # from the Prism comments. This recovers them from the AST, excluding escapes.
          # Intention is to remove this once the bug is fixed upstream in Herb.
          if node.is_a?(Herb::AST::ERBContentNode) && %w[<% <%-].include?(node.tag_opening.value) &&
             node.content.value.match?(/\A[^\S\r\n]*#[^\r\n]*\z/)
            token = node.content
            offset = token.range.from + token.value.b.index('#')
            @comments << Comment.new(token.value.lstrip, token.location.start.line, byte_column(bytes, offset))
          end
        end

        node.compact_child_nodes.each do |child|
          collect_erb_comments(child, bytes, ruby_ranges)
        end
      end

      def process_erb_comment(token, bytes)
        start = token.location.start
        column = byte_column(bytes, token.range.from)
        token.value.each_line.with_index do |text, index|
          @comments << Comment.new(text, start.line + index, index.zero? ? column : 0)
        end
      end

      def byte_column(bytes, offset)
        line_start = (bytes.rindex("\n", offset - 1) || -1) + 1
        offset - line_start
      end
    end
  end
end
