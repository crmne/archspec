---
title: Dependencies
nav_order: 2
description: Use ArchSpec dependency rules to define component allowlists, deny specific dependencies, restrict consumers, and expose public APIs.
---

# Dependencies

Use dependency rules when one component should or should not reference another component.

## Allow Only These Components

```ruby
controllers.can_only_use :models, :services
```

Rule id: `dependencies.allow`

`can_only_use` is an allowlist. References from `controllers` to any other declared component fail.

## Forbid Specific Components

```ruby
models.cannot_use :controllers
```

Rule id: `dependencies.forbid`

`cannot_use` is narrower. References to listed components fail; other declared dependencies are allowed unless another rule forbids them.

## Allow Only These Consumers

```ruby
shared_kernel.can_only_be_used_by :billing, :catalog
```

Rule id: `dependencies.consumers`

The inverse of `can_only_use`. Where `can_only_use` limits who a component may depend on, `can_only_be_used_by` limits who may depend on it. A reference from any other component fails. Use it to protect a shared kernel or a component with a deliberately narrow audience. The component may still reference itself.

## Public API

```ruby
billing.public_api "packs/billing/app/public/**/*.rb"
```

Rule id: `dependencies.privacy`

`public_api` marks part of a component as its front door. References from outside the component must resolve to a constant defined in a public file. Everything else in the component becomes private, and outside references to it fail.

Name the public surface by constant or namespace when it does not map to a directory:

```ruby
billing.public_api constants: "Billing::Api"
billing.public_api namespace: "Billing::Public"
```

`constants` matches exact names. `namespace` matches a name and everything under it. Code inside the component may still reach its own private constants.

## What Counts

ArchSpec checks visible dependency edges:

- constant references
- inheritance
- `include`
- `prepend`
- `extend`

It does not build a whole-program call graph.

A target defined in a gem is a name the tree does not define, so it lands in no component, unless a resolver is declared and a component owns it by `namespace:` or `constants:`; then the edge into it counts like any other, and the gem constant is still never a member of the component that owns it.
