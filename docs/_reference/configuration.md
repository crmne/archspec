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
  root "."
  source "app/**/*.rb", "lib/**/*.rb"
  ignore "tmp/**/*", "vendor/**/*"
  baseline ".archspec_todo.yml"
end
```

`root` is resolved relative to the config file.

## Components

```ruby
component :controllers, in: "app/controllers/**/*.rb"
component :models,      in: "app/models/**/*.rb"
component :billing,     namespace: "Billing"
```

`component`, `layer`, and `role` are aliases. Use the word that matches the architecture you are describing.

## Dependency Rules

```ruby
controllers.can_use :models, :services
models.cannot_use :controllers
```

`can_use` is an allowlist for other declared components. `cannot_use` forbids specific components.

## Method Rules

```ruby
services.must_implement :call
services.must_implement_one_of :call, :resolve
services.cannot_call :render, :redirect_to, :params, :session
```

These are name-based checks. They are useful for Rails boundaries and callable object conventions.

For projects that avoid anonymous command-object style APIs, forbid method definitions too:

```ruby
library.cannot_define :call
```

## Constant Rules

```ruby
models.cannot_reference_constants "ActionController", "ActionView"
```

Use this when the dependency is better expressed as a framework constant than a component.

## Presets

```ruby
preset :rails_way
```

The Rails preset is intentionally small. Add your own rules beside it.

## Cycles and Names

```ruby
no_cycles!
verify_zeitwerk_names!
```

`no_cycles!` checks component dependency cycles. `verify_zeitwerk_names!` checks file-to-constant naming for conventional Rails paths.

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
