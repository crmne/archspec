---
title: Protocols
nav_order: 4
description: Use ArchSpec protocol rules to require classes in a component to implement one method or at least one member of an accepted method set.
---

# Protocols

Protocol rules check that classes in a component expose an expected API through
their own definitions, resolvable superclasses, or mixins.

## Require One Method

```ruby
services.must_implement :call
```

Rule id: `protocol.must_implement`

Check the class side with `scope: :class`. Class methods inherited from a
superclass or acquired through `extend` count:

```ruby
jobs.must_implement :perform_later, scope: :class
```

Require a callable shape with `arity:` and `keywords:`:

```ruby
commands.must_implement :call, arity: 1, keywords: %i[actor request_id]
```

`arity:` means the method must accept that many positional arguments, so an
optional or rest parameter can satisfy it. Required, optional, and rest
keywords are handled the same way. A generated method whose signature is not
known produces a medium-confidence finding rather than being assumed correct.

## Require One Of Several Methods

```ruby
queries.must_implement_one_of :call, :resolve
jobs.must_implement_one_of :enqueue, :perform_later, scope: :class
```

Rule id: `protocol.must_implement_one_of`

These checks verify API shape, not behavior or return types.
