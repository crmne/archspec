# frozen_string_literal: true

require 'pathname'

require_relative 'value_object'

module ArchSpec
  SourceLocation = ValueObject.define(:path, :line, :column) do
    def self.from_prism(path, location)
      new(path, location.start_line, location.start_column + 1)
    end

    def relative_path(root)
      Pathname(path).relative_path_from(Pathname(root)).to_s
    rescue ArgumentError
      path
    end
  end
end
