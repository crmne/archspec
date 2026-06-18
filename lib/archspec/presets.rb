# frozen_string_literal: true

module ArchSpec
  module Presets
    module_function

    def apply(name, dsl, **options)
      Architectures.apply(name, dsl, **options)
    end
  end
end
