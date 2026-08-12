# frozen_string_literal: true

require 'pathname'

require_relative 'value_object'

module ArchSpec
  SourceLocation = ValueObject.define(:path, :line, :column, :end_line, :end_column) do
    def self.from_prism(path, location)
      new(path, location.start_line, location.start_column + 1, location.end_line, location.end_column + 1)
    end

    # A zero-width location for diagnostics that point at a file rather than a
    # span of code.
    def self.point(path, line, column)
      new(path, line, column, line, column)
    end

    def relative_path(root)
      Pathname(path).relative_path_from(Pathname(root)).to_s
    rescue ArgumentError
      path
    end
  end
end
