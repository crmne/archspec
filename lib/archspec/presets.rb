module ArchSpec
  module Presets
    module_function

    def apply(name, dsl)
      case name.to_sym
      when :rails_way
        rails_way(dsl)
      else
        raise Error, "Unknown ArchSpec preset: #{name.inspect}"
      end
    end

    def rails_way(dsl)
      dsl.component :controllers, in: "app/controllers/**/*.rb"
      dsl.component :models, in: "app/models/**/*.rb"
      dsl.component :helpers, in: "app/helpers/**/*.rb"
      dsl.component :mailers, in: "app/mailers/**/*.rb"
      dsl.component :jobs, in: "app/jobs/**/*.rb"
      dsl.component :services, in: "app/services/**/*.rb"

      dsl.controllers.can_use :models, :services, :helpers, :mailers, :jobs
      dsl.models.cannot_use :controllers, :helpers
      dsl.services.cannot_use :controllers, :helpers

      controller_methods = %i[render redirect_to params session cookies flash]
      dsl.models.cannot_call(*controller_methods)
      dsl.services.cannot_call(*controller_methods)
    end
  end
end
