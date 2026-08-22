# frozen_string_literal: true

source 'lib/**/*.rb'

component :library, in: 'lib/**/*.rb'
component :public_api, in: 'lib/archspec.rb'
component :cli, in: 'lib/archspec/cli.rb'
component :analysis, in: %w[
  lib/archspec/analyzer.rb
  lib/archspec/evaluator.rb
]
component :domain, in: %w[
  lib/archspec/todo.rb
  lib/archspec/facts.rb
  lib/archspec/snapshot.rb
  lib/archspec/delta.rb
  lib/archspec/component_spec.rb
  lib/archspec/definition.rb
  lib/archspec/diagnostic.rb
  lib/archspec/model.rb
  lib/archspec/source_location.rb
]
component :dsl, in: %w[
  lib/archspec/architectures.rb
  lib/archspec/dsl.rb
]
component :rule_checks, in: 'lib/archspec/rules/**/*.rb'
component :formatters, in: 'lib/archspec/formatters/**/*.rb'
component :reflect, in: %w[
  lib/archspec/reflect.rb
  lib/archspec/associations.rb
]
component :support, in: %w[
  lib/archspec/error.rb
  lib/archspec/value_object.rb
  lib/archspec/version.rb
]

library.cannot_call :call
library.cannot_define :call
library.cannot_instantiate_and_invoke

domain.cannot_use :analysis, :cli, :dsl, :formatters, :rule_checks
rule_checks.cannot_use :analysis, :cli, :dsl, :formatters
formatters.cannot_use :analysis, :cli, :dsl, :rule_checks
dsl.cannot_use :analysis, :cli, :formatters
reflect.cannot_use :analysis, :cli, :dsl, :formatters, :rule_checks

no_cycles among: %i[public_api cli analysis domain dsl rule_checks formatters reflect support]
