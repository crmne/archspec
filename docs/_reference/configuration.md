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
facts "archspec_facts"
cache ".archspec/cache"
```
{: data-title="Archspec.rb"}

Todo ids are computed from the rule, path, message, and evidence, not the line number, so entries survive edits that shift code.

`facts` names the directory of producer-written facts files merged before rules run; it defaults to `archspec_facts/`. With `associations: :static` the Active Record associations the source states outright are merged on every check without booting. See [Facts](facts/).

`cache` keeps what the parser extracted from each file between runs, keyed by the file's content and the gem and parser versions, so a check re-reads only what changed, and lets a path-scoped check reuse a snapshot for every file it does not name. It is off until declared; the directory defaults to `.archspec/cache/` and ignores itself in git. The output with and without the cache is the same, byte for byte.

## Components

```ruby
component :controllers, in: "app/controllers/**/*.rb"
component :models,      in: "app/models/**/*.rb"
component :billing,     namespace: "Billing"
component :domain,      in: "app/models/**/*.rb", except: "app/models/**/*_workflow.rb"
component :workflows,   in: "app/models/**/*_workflow.rb"
```

`except:` removes files from what `in:` matched, and only those: a file the component also claims through `namespace:` or `constants:` stays a member. A component with `except:` and no `in:` is an error. A few files that need wider grants than their layer become their own component with their own allowlist, instead of a hole in the layer's. The same keyword works inside the hash form every architecture accepts, so a layer in `layers:` can read `{ in: "app/models/**/*.rb", except: "app/models/**/*_workflow.rb" }`.

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

## Cycles

```ruby
no_cycles
```

`no_cycles` checks component dependency cycles.

See [Cycle Rules]({% link _rules/cycles.md %}).

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
