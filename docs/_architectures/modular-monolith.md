---
title: Modular Monolith
nav_order: 7
description: Enforce allowed dependencies between application modules.
---

# Modular Monolith

Use this when the app is organized into named packages, packs, engines, or bounded contexts.

```ruby
architecture :modular_monolith,
  components: {
    billing: "packs/billing/**/*.rb",
    catalog: "packs/catalog/**/*.rb",
    shared: "packs/shared/**/*.rb"
  },
  allow: {
    billing: %i[shared],
    catalog: %i[shared]
  }
```

Every component gets an allowlist. If a component is omitted from `allow`, it may not depend on any other declared component.

Add `public` to force other packs through a front door instead of reaching into internals:

```ruby
architecture :modular_monolith,
  components: {
    billing: "packs/billing/**/*.rb",
    catalog: "packs/catalog/**/*.rb"
  },
  allow: {
    catalog: %i[billing]
  },
  public: {
    billing: "packs/billing/app/public/**/*.rb"
  }
```

`catalog` may depend on `billing`, but only on constants defined under `billing`'s public files. See [Public API]({% link _rules/dependencies.md %}).

ArchSpec also adds a cycle check across the declared components.

## Engines and Packs

Engines and packs are the same topology: named packages under a parent directory. Rather than list them by hand, declare one component per subdirectory with `each_directory`. It resolves paths against the `Archspec.rb` location, so it works no matter where `archspec` runs from.

```ruby
each_directory "engines/*" do |name, path|
  component name, in: "#{path}/**/*.rb"
end

component :shared, in: "engines/shared/**/*.rb"

billing.can_only_use :shared
catalog.can_only_use :shared
no_cycles
```

`Archspec.rb` is plain Ruby, so you keep full control: skip a directory, rename a component, or attach different rules per package inside the block.
