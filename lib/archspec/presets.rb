# frozen_string_literal: true

module ArchSpec
  module Presets
    module_function

    def apply(name, dsl, **options)
      case name.to_sym
      when :rails_way, :rails_mvc
        rails_way(dsl, **options)
      when :rails_strict
        rails_strict(dsl, **options)
      when :vanilla_rails
        vanilla_rails(dsl, **options)
      when :rails_layered
        rails_layered(dsl, **options)
      when :rails_hexagonal
        rails_hexagonal(dsl, **options)
      when :rails_clean
        rails_clean(dsl, **options)
      when :rails_cqrs
        rails_cqrs(dsl, **options)
      when :rails_event_driven
        rails_event_driven(dsl, **options)
      else
        raise Error, "Unknown ArchSpec preset: #{name.inspect}"
      end
    end

    def rails_way(dsl, **options)
      Architectures.apply(:rails_mvc, dsl, **options)
    end

    def rails_strict(dsl, **options)
      rails_way(dsl, **options)
      dsl.verify_zeitwerk_names!
      dsl.no_cycles!(among: %i[controllers models helpers mailers jobs services])
    end

    VANILLA_RAILS_EMPTY = {
      services: ['app/services/**/*.rb', 'behavior belongs on models, not service objects'],
      forms: ['app/forms/**/*.rb', 'use strong parameters and model validations'],
      policies: ['app/policies/**/*.rb', 'authorization is predicate methods on models'],
      decorators: ['app/decorators/**/*.rb', 'use helpers and partials'],
      presenters: ['app/presenters/**/*.rb', 'presentation objects are POROs in app/models'],
      view_components: ['app/components/**/*.rb', 'use helpers and ERB partials']
    }.freeze

    def vanilla_rails(dsl, **options)
      rails_way(dsl, **options)

      VANILLA_RAILS_EMPTY.each do |name, (pattern, reason)|
        dsl.component(name, in: pattern).must_be_empty(because: reason)
      end
    end

    def rails_layered(dsl, **options)
      Architectures.apply(:layered, dsl, **options)
    end

    def rails_hexagonal(dsl, **options)
      Architectures.apply(:hexagonal, dsl, **options)
    end

    def rails_clean(dsl, **options)
      Architectures.apply(:clean, dsl, **options)
    end

    def rails_cqrs(dsl, **options)
      Architectures.apply(:cqrs, dsl, **options)
    end

    def rails_event_driven(dsl, **options)
      Architectures.apply(:event_driven, dsl, **options)
    end
  end
end
