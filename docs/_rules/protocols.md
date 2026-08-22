---
title: Protocols
nav_order: 4
description: Use ArchSpec protocol rules to require classes in a component to implement one method or at least one member of an accepted method set.
---

# Protocols

Protocol rules check that classes in a component define expected methods. Instance methods by default; pass `scope: :class` for a class-side protocol.

## Require One Method

```ruby
services.must_implement :call
```

Rule id: `protocol.must_implement`

## Require One Of Several Methods

```ruby
queries.must_implement_one_of :call, :resolve
```

Rule id: `protocol.must_implement_one_of`

## Class-Side Protocols

```ruby
jobs.must_implement :perform_later, scope: :class
```

With `scope: :class` the rule counts the class's own class methods, the instance methods of every module it `extend`s, and the class methods of its superclass chain. An ancestor ArchSpec cannot resolve lowers the diagnostic to medium confidence, as it does for instance protocols.

These checks are intentionally simple. They verify the visible method definitions in source. They do not prove behavior.
