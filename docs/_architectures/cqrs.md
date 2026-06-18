---
title: CQRS
nav_order: 8
description: Keep command and query code separated.
---

# CQRS

CQRS is modeled as commands, queries, and optional read models.

```ruby
architecture :cqrs
```

This checks:

- commands do not depend on queries
- queries do not depend on commands
- queries do not call obvious mutating methods such as `save!`, `update!`, or `destroy!`
- the declared components do not form cycles

The default Rails-flavored directories are:

```ruby
commands: "app/commands/**/*.rb"
queries: "app/queries/**/*.rb"
read_models: "app/read_models/**/*.rb"
```

Pass any of those keys to override the defaults.

This is a structural check. It does not prove that every read and write path obeys CQRS at runtime.
