module ArchSpec
  module Presets
    module_function

    def apply(name, dsl, **options)
      case name.to_sym
      when :rails_way, :rails_mvc
        rails_way(dsl, **options)
      when :rails_strict
        rails_strict(dsl, **options)
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
