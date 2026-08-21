---
title: Cycles
nav_order: 7
description: Use ArchSpec cycle rules to detect circular dependencies between declared components and report the concrete evidence that closes each cycle.
seo:
  title: Dependency cycle rules
---

# Cycles

Cycles make architecture harder to change because two components become one unit in practice.

```ruby
no_cycles
```

Rule id: `dependencies.no_cycles`

Limit the check to specific components:

```ruby
no_cycles among: %i[ui domain infra]
```

ArchSpec builds the component dependency graph from visible dependency edges and reports cycles such as:

```text
component dependency cycle: domain -> infra -> domain
```

A group of components that all reach each other is reported once, not once per
route through it. When the group is larger than the cycle shown, the message
names every component in it and the note carries the shortest cycle to break:

```text
component dependency cycle among 4 components: billing, catalog, orders, shipping

  note: billing -> orders -> billing
```
