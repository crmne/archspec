ArchSpec.define "ArchSpec architecture" do
  root "."
  source "lib/**/*.rb"

  component :library, in: "lib/**/*.rb"
  component :public_api, in: "lib/archspec.rb"
  component :cli, in: "lib/archspec/cli.rb"
  component :analysis, in: %w[
    lib/archspec/analyzer.rb
    lib/archspec/evaluator.rb
  ]
  component :domain, in: %w[
    lib/archspec/baseline.rb
    lib/archspec/component_spec.rb
    lib/archspec/definition.rb
    lib/archspec/diagnostic.rb
    lib/archspec/model.rb
    lib/archspec/source_location.rb
  ]
  component :dsl, in: %w[
    lib/archspec/dsl.rb
    lib/archspec/presets.rb
  ]
  component :rule_checks, in: "lib/archspec/rules/**/*.rb"
  component :formatters, in: "lib/archspec/formatters/**/*.rb"
  component :support, in: "lib/archspec/version.rb"

  library.cannot_call :call
  library.cannot_define :call
  library.cannot_instantiate_and_invoke

  domain.cannot_use :analysis, :cli, :dsl, :formatters, :rule_checks
  rule_checks.cannot_use :analysis, :cli, :dsl, :formatters
  formatters.cannot_use :analysis, :cli, :dsl, :rule_checks
  dsl.cannot_use :analysis, :cli, :formatters

  no_cycles! among: %i[public_api cli analysis domain dsl rule_checks formatters support]
end
