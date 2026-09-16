---
title: Configuration
nav_order: 1
description: Complete reference for the Archspec.rb DSL, including sources, components, dependency rules, protocols, naming rules, baselines, and presets.
---

# Configuration

`Archspec.rb` is Ruby.

## Project

```ruby
source "app/**/*.rb", "lib/**/*.rb"
ignore "tmp/**/*", "vendor/**/*"
todo "archspec_todo.yml"
```
{: data-title="Archspec.rb"}

ArchSpec analyzes `.rb` and `.rake` files matched by source or component
patterns. The default source patterns select `.rb` files; opt into Rake tasks
with `source "app/**/*.rb", "lib/**/*.{rb,rake}"` or a component such as
`component :tasks, in: "lib/tasks/**/*.rake"`. Ignore patterns apply to both.

Todo ids are computed from the rule, path, message, and evidence, not the line number, so entries survive edits that shift code.

Opt into externally produced association or generated-method facts with
`facts "archspec_facts"`. `check` and `explain` read the directory's `.yml`
snapshots without running the application. `archspec reflect` explicitly boots
Rails to produce `rails.yml`. Missing or stale configured snapshots fail the
check. See [Association reflection]({% link _guides/association-reflection.md %})
for Rails and [Framework integrations]({% link _guides/framework-integrations.md %})
for custom producers.

## Components

```ruby
component :controllers, in: "app/controllers/**/*.rb"
component :models,      in: "app/models/**/*.rb"
component :billing,     namespace: "Billing"
component :records,     descendants_of: "ApplicationRecord"
component :workflows,
  in: "app/models/**/*.rb",
  except: "app/models/**/*_workflow.rb"
```

`except:` subtracts only from the `in:` patterns. Explicit `namespace:`,
`constants:`, and `descendants_of:` selectors remain explicit. The same hash
form works inside architecture options such as `layers:` and `components:`.

Declare one component per subdirectory with `each_directory`, which is handy for engines and packs:

```ruby
each_directory "packs/*" do |name, path|
  component name, in: "#{path}/**/*.rb"
end
```

## Architectures

```ruby
architecture :layered, layers: {
  interface: "app/controllers/**/*.rb",
  application: "app/services/**/*.rb",
  domain: "app/models/**/*.rb"
}
```

Architectures define components and rules together. See [Architectures]({% link _architectures/index.md %}).

## Dependency Rules

```ruby
controllers.can_only_use :models, :services
models.cannot_use :controllers
shared_kernel.can_only_be_used_by :billing, :catalog
```

`can_only_use` is an allowlist for what a component may depend on. `cannot_use` forbids specific components. `can_only_be_used_by` is the inverse of `can_only_use`: it limits who may depend on the component. See [Dependency Rules]({% link _rules/dependencies.md %}).

## Method Rules

```ruby
services.must_implement :call
services.must_implement_one_of :call, :resolve
services.cannot_call :render, :redirect_to, :params, :session
jobs.must_implement :perform_later, scope: :class
commands.must_implement :call, arity: 1, keywords: :actor
models.cannot_call :find_by_sql, receiver: "ActiveRecord::Base"
```

RubyDEX resolves static constant receivers, class-side ancestry, method aliases,
and method signatures for these checks. Calls through dynamic receivers remain
unknown rather than guessed. See [Method Rules]({% link _rules/methods.md %})
and [Protocol Rules]({% link _rules/protocols.md %}).

For projects that avoid anonymous command-object style APIs, forbid method definitions too:

```ruby
library.cannot_define :call
library.cannot_instantiate_and_invoke
```

See [Object Rules]({% link _rules/objects.md %}).

## Constant Rules

```ruby
models.cannot_reference_constants "ActionController", "ActionView"
```

Use this when the dependency is better expressed as a framework constant than a component.

See [Constant Rules]({% link _rules/constants.md %}).

## Cycles

```ruby
no_cycles
```

`no_cycles` checks component dependency cycles.

See [Cycle Rules]({% link _rules/cycles.md %}).

## Reasons

Every rule-creating call accepts `because:`:

```ruby
models.cannot_use :controllers,
  because: "models must remain independent of the request"
```

The reason is printed with each finding and included in JSON, but stays outside
the todo fingerprint. Adding or editing a reason does not invalidate an
existing todo file. Repeating the same merged rule with two different reasons
is rejected when the configuration loads.

## Suppressions

```ruby
# archspec:disable-next-line dependencies.forbid -- legacy export
Admin::UsersController
```

Supported forms:

```text
archspec:disable-next-line RULE -- reason
archspec:disable-line RULE -- reason
archspec:disable RULE -- reason
archspec:enable RULE
```

Omit `RULE` to suppress all ArchSpec rules on that line or block.
