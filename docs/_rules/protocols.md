---
title: Protocols
nav_order: 4
description: Use ArchSpec protocol rules to require classes in a component to implement one method or at least one member of an accepted method set.
---

# Protocols

Protocol rules check that classes in a component define expected instance methods.

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

These checks are intentionally simple. They verify the visible method definitions in source. They do not prove behavior.
