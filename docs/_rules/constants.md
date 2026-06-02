---
title: Constants
nav_order: 6
description: Forbid references to specific constants.
---

# Constants

Use constant rules when the boundary is best described by a framework or library constant.

```ruby
models.cannot_reference_constants "ActionController", "ActionView"
```

Rule id: `constants.forbid`

This fails when a file in the component references the constant or anything under it.

For component-to-component boundaries, prefer [dependency rules]({% link _rules/dependencies.md %}).
