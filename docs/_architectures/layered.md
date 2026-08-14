---
title: Layered
nav_order: 4
description: Use ArchSpec's layered architecture preset to define ordered application layers, enforce inward dependencies, and detect dependency cycles.
seo:
  title: Layered architecture preset
---

# Layered

Layered architecture is an ordered list. Earlier layers may depend on later layers. Later layers may not depend back outward.

```ruby
architecture :layered
```

This compiles to:

- components named `interface`, `application`, and `domain`
- allowlist dependency rules in layer order
- a cycle check across the layers

The default Rails-flavored layers are:

```ruby
interface: "app/controllers/**/*.rb"
application: %w[app/services/**/*.rb app/jobs/**/*.rb app/mailers/**/*.rb]
domain: "app/models/**/*.rb"
```

Override them when the app uses different directories:

```ruby
architecture :layered, layers: {
  interface: "app/controllers/**/*.rb",
  application: "app/services/**/*.rb",
  domain: "app/models/**/*.rb"
}
```
