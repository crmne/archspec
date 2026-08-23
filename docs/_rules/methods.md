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

`pdf.render` and `client.params` then pass, while a bare `render` or `params` fails. Pass a constant name to match only calls sent to that constant or one of its descendants:

```ruby
models.cannot_call :find_by_sql, receiver: "ActiveRecord::Base"
```

`User.find_by_sql` then fails through `User`'s chain, while `conn.find_by_sql` passes, because a receiver the graph did not type never matches a named one. The chain is the engine's when `resolver :rubydex` is declared and the parser's `inherits_from` edges otherwise, and a call through `alias_method` matches the method it aliases.

`pdf.render` and `client.params` pass with `receiver: :none`, while a bare `render` or `params` fails. The `:rails` architectures use `receiver: :none` for the controller API. A bare call to a method the component defines, inherits, or generates with `attr_*`, Rails `attribute`, `alias_attribute`, `enum`, `store_accessor`, `delegate`, or an Active Record association macro is treated as a call to its own API and is not flagged. The association macros cover the reader and writer, plus the `build_`, `create_`, and `reload_` helpers on `belongs_to` and `has_one`.

## Forbid Parameter Shapes

```ruby
public_api.cannot_take :block, :rest
services.cannot_take keyword: :options
```

Rule id: `methods.take_forbid`

This fails when a public method defined in the component takes a block parameter, a rest parameter, or the named keyword, read off the parser's parameter list or a facts file's `definitions` entry. A definition nobody described has no signature and is not flagged.

## Forbid Definitions

```ruby
library.cannot_define :call
```

Rule id: `methods.define_forbid`

This catches classes in the component that define the named method.

Use it when the method name itself is a design smell in that component.
