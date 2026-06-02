---
title: Layered
nav_order: 3
description: Enforce inward dependencies through ordered layers.
---

# Layered

Layered architecture is an ordered list. Earlier layers may depend on later layers. Later layers may not depend back outward.

```ruby
architecture :layered, layers: {
  interface: "app/controllers/**/*.rb",
  application: "app/services/**/*.rb",
  domain: "app/models/**/*.rb"
}
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

You can also use:

```ruby
preset :rails_layered
```
