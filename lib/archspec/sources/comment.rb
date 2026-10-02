# frozen_string_literal: true

module ArchSpec
  module Sources
    # Parser-independent comment text and position for suppression handling.
    # Lines are one-based and columns are zero-based byte offsets within a line.
    Comment = Data.define(:text, :line, :column) do
      def self.from_prism(comment)
        location = comment.location
        new(comment.slice, location.start_line, location.start_column)
      end
    end
  end
end
