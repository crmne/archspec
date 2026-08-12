# frozen_string_literal: true

module ArchSpec
  # Raised for configuration and usage errors, such as an unknown architecture
  # name or a malformed rule option.
  class Error < StandardError; end
end
