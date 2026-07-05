---
title: Ruby Conventions
nav_order: 10
description: Generic Ruby naming idioms, applied project-wide.
---

# Ruby Conventions

Ruby Conventions bundles the generic Ruby naming idioms and applies them to every method in the project.

```ruby
architecture :ruby_conventions
```

This checks:

- no `get_` or `set_` accessor prefixes, across all public methods
- no `is_` predicate prefix (Ruby predicates end in `?`)

`has_` is left alone, because Rails uses `has_many` and `has_one`, and `has_access?` style predicates are legitimate.

It adds no components, so it composes with any other architecture:

```ruby
architecture :rails
architecture :ruby_conventions
```

The checks are name-based and exact, reported at `high` confidence.

Project-specific conventions stay opt-in through the [naming rules]({% link _rules/naming.md %}), which is where the `with_x` / `without_x` pairing, the `supports_*?` ban, and cross-component correspondences live:

```ruby
chat.methods.matching(/\Awith_(?<base>.+)/).requires("without_%{base}")
```
