---
title: CQRS
nav_order: 7
description: Keep command and query code separated.
---

# CQRS

CQRS is modeled as commands, queries, and optional read models.

```ruby
architecture :cqrs,
  commands: "app/commands/**/*.rb",
  queries: "app/queries/**/*.rb",
  read_models: "app/read_models/**/*.rb"
```

This checks:

- commands do not depend on queries
- queries do not depend on commands
- queries do not call obvious mutating methods such as `save!`, `update!`, or `destroy!`
- the declared components do not form cycles

The Rails default is:

```ruby
preset :rails_cqrs
```

This is a structural check. It does not prove that every read and write path obeys CQRS at runtime.
