---
title: Dependencies
nav_order: 2
description: Allow or forbid dependencies between components.
---

# Dependencies

Use dependency rules when one component should or should not reference another component.

## Allow Only These Components

```ruby
controllers.can_use :models, :services
```

Rule id: `dependencies.allow`

`can_use` is an allowlist. References from `controllers` to any other declared component fail.

## Forbid Specific Components

```ruby
models.cannot_use :controllers
```

Rule id: `dependencies.forbid`

`cannot_use` is narrower. References to listed components fail; other declared dependencies are allowed unless another rule forbids them.

## What Counts

ArchSpec checks visible dependency edges:

- constant references
- inheritance
- `include`
- `prepend`
- `extend`

It does not build a whole-program call graph.
