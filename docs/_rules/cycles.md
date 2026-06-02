---
title: Cycles
nav_order: 7
description: Detect cycles between component dependencies.
---

# Cycles

Cycles make architecture harder to change because two components become one unit in practice.

```ruby
no_cycles!
```

Rule id: `dependencies.no_cycles`

Limit the check to specific components:

```ruby
no_cycles! among: %i[ui domain infra]
```

ArchSpec builds the component dependency graph from visible dependency edges and reports cycles such as:

```text
component dependency cycle: domain -> infra -> domain
```
