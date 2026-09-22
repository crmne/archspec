# frozen_string_literal: true

module ArchSpec
  module Sources
    Comment = Data.define(:text, :line, :column) do
      def self.from_prism(comment)
        location = comment.location
        new(comment.slice, location.start_line, location.start_column)
      end
    end
  end
end
