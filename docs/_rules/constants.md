---
title: Constants
nav_order: 6
description: Use ArchSpec constant rules to forbid references to named Ruby constants and anything nested beneath them across component boundaries.
---

# Constants

Use constant rules when the boundary is best described by a framework or library constant.

```ruby
models.cannot_reference_constants "ActionController", "ActionView"
```

Rule id: `constants.forbid`

This fails when a file in the component references the constant or anything under it. With a resolver declared the rule also matches the constant under every alias the engine resolved, and the evidence names the alias and its target.

For component-to-component boundaries, prefer [dependency rules]({% link _rules/dependencies.md %}).
