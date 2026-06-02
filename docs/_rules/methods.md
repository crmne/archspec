---
title: Methods
nav_order: 3
description: Forbid method calls or method definitions.
---

# Methods

Method rules are name-based. They are useful for Rails boundary checks and project style conventions.

## Forbid Calls

```ruby
services.cannot_call :render, :redirect_to, :params, :session
```

Rule id: `methods.forbid`

This catches method sends from files assigned to the component.

## Forbid Definitions

```ruby
library.cannot_define :call
```

Rule id: `methods.define_forbid`

This catches classes in the component that define the named method.

Use it when the method name itself is a design smell in that component.
