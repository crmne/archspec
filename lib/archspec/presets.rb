# frozen_string_literal: true

module ArchSpec
  # Backwards-compatible alias for ArchSpec::Architectures. New code should use
  # +architecture+ in the DSL and the ArchSpec::Architectures module.
  module Presets
    module_function

    # Delegates to ArchSpec::Architectures.apply.
    def apply(name, dsl, **options)
      Architectures.apply(name, dsl, **options)
    end
  end
end
