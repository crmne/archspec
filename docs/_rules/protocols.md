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

## What The Method Takes

```ruby
services.must_implement :call, arity: 1, keyword: :actor
commands.must_implement :perform, arity: 0..2
```

`arity:` is a count or a range of required positionals the implementation must accept, `keyword:` one or more keywords it must take. Both read the signature the parser recorded, or the one a facts file stated for a definition the parser could not see. The check runs only when a resolver is declared; a definition with no recorded signature is reported as such, never read as conforming.

## Through The Engine's Chain

With `resolver :rubydex` declared the engine's linearised ancestry is the authority: a protocol satisfied through a framework ancestor, `perform_later` on a job through `ActiveJob::Base`, is reported at high confidence with the supplying ancestor in the evidence. A chain the engine marks as dynamic keeps the parser's walk and medium confidence, with the engine's diagnostic named in the caveat.

These checks are intentionally simple. They verify the visible method definitions in source. They do not prove behavior.
