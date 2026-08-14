---
title: Hexagonal
nav_order: 5
description: Use ArchSpec's hexagonal architecture preset to keep domain code and ports independent from adapters and infrastructure concerns.
---

# Hexagonal

Hexagonal architecture separates the application core from adapters.

```ruby
architecture :hexagonal
```

This creates four components:

- `application`
- `domain`
- `ports`
- `adapters`

The core rules are:

- `domain` must not use `adapters`
- `ports` must not use `adapters`
- `application` can use `domain` and `ports`
- `adapters` can use `application`, `domain`, and `ports`
- no cycles across the four components

The default Rails-flavored directories are:

```ruby
application: %w[app/services/**/*.rb app/use_cases/**/*.rb]
domain: "app/domain/**/*.rb"
ports: "app/ports/**/*.rb"
adapters: %w[app/adapters/**/*.rb app/integrations/**/*.rb app/infrastructure/**/*.rb]
```

Pass any of those keys to override the defaults.
