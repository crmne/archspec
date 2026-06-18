---
title: Configuration
nav_order: 1
description: The Archspec.rb DSL.
---

# Configuration

`Archspec.rb` is Ruby. Keep it boring.

## Project

```ruby
ArchSpec.define "Application architecture" do
  source "app/**/*.rb", "lib/**/*.rb"
  ignore "tmp/**/*", "vendor/**/*"
  baseline ".archspec_todo.yml"
end
```

The project root defaults to the directory containing `Archspec.rb`. Use `root` only when the code you want to analyze lives somewhere else; it is resolved relative to the config file.

## Components

```ruby
component :controllers, in: "app/controllers/**/*.rb"
component :models,      in: "app/models/**/*.rb"
component :billing,     namespace: "Billing"
```

`component`, `layer`, and `role` are aliases. Use the word that matches the architecture you are describing.

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
controllers.can_use :models, :services
models.cannot_use :controllers
```

`can_use` is an allowlist for other declared components. `cannot_use` forbids specific components. See [Dependency Rules]({% link _rules/dependencies.md %}).

## Method Rules

```ruby
services.must_implement :call
services.must_implement_one_of :call, :resolve
services.cannot_call :render, :redirect_to, :params, :session
```

These are name-based checks. They are useful for Rails boundaries and method protocols. See [Method Rules]({% link _rules/methods.md %}) and [Protocol Rules]({% link _rules/protocols.md %}).

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

## Presets

```ruby
preset :rails_way
preset :rails_layered
```

Presets are shortcuts for common Rails checks and architecture bundles. Add your own rules beside them.

See [Presets]({% link _architectures/presets.md %}).

## Cycles and Names

```ruby
no_cycles!
verify_zeitwerk_names!
```

`no_cycles!` checks component dependency cycles. `verify_zeitwerk_names!` checks file-to-constant naming for conventional Rails paths.

See [Cycle Rules]({% link _rules/cycles.md %}) and [Zeitwerk Name Rules]({% link _rules/zeitwerk-names.md %}).

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
