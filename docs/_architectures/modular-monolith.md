---
title: Modular Monolith
nav_order: 6
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

Alias:

```ruby
architecture :bounded_contexts, components: { ... }, allow: { ... }
```

ArchSpec also adds a cycle check across the declared components.
