---
title: Hexagonal
nav_order: 4
description: Keep domain and ports independent from adapters.
---

# Hexagonal

Hexagonal architecture separates the application core from adapters.

```ruby
architecture :hexagonal,
  application: %w[app/services/**/*.rb app/use_cases/**/*.rb],
  domain: "app/domain/**/*.rb",
  ports: "app/ports/**/*.rb",
  adapters: %w[app/adapters/**/*.rb app/integrations/**/*.rb]
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

Use the Rails defaults with:

```ruby
preset :rails_hexagonal
```
