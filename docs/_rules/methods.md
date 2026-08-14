---
title: Methods
nav_order: 3
description: Use ArchSpec method rules to forbid calls to selected APIs or prevent components from defining methods that violate architecture boundaries.
seo:
  title: Method boundary rules
---

# Methods

Method rules are name-based. They are useful for Rails boundary checks and project style conventions.

## Forbid Calls

```ruby
services.cannot_call :render, :redirect_to, :params, :session
```

Rule id: `methods.forbid`

This catches method sends from files assigned to the component.

By default a call matches whatever the receiver is, so `queries.cannot_call :update` flags `user.update` and `cache.update` alike. Pass `receiver: :none` to match only bare calls, where the receiver is implicit `self`:

```ruby
services.cannot_call :render, :params, receiver: :none
```

`pdf.render` and `client.params` then pass, while a bare `render` or `params` fails. The `:rails` architectures use `receiver: :none` for the controller API. A bare call to a method the component defines, inherits, or generates with `attr_*`, Rails `attribute`, or `delegate` is treated as a call to its own API and is not flagged.

## Forbid Definitions

```ruby
library.cannot_define :call
```

Rule id: `methods.define_forbid`

This catches classes in the component that define the named method.

Use it when the method name itself is a design smell in that component.
