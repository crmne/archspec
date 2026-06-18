---
title: Event Driven
nav_order: 8
description: Keep event definitions independent from publishers and subscribers.
---

# Event Driven

Event-driven architecture is modeled as events, publishers, and subscribers.

```ruby
architecture :event_driven
```

This checks:

- event definitions do not depend on publishers or subscribers
- publishers only depend on declared events
- subscribers only depend on declared events
- the declared components do not form cycles

The default Rails-flavored directories are:

```ruby
events: "app/events/**/*.rb"
publishers: "app/publishers/**/*.rb"
subscribers: "app/subscribers/**/*.rb"
```

Pass any of those keys to override the defaults.

This is intentionally narrow. It checks source-level coupling, not event delivery semantics.
