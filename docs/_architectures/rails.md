---
title: Rails
nav_order: 2
description: Check conventional Rails boundaries.
---

# Rails

Rails is the default Rails architecture bundle.

```ruby
architecture :rails
```

This defines:

- `controllers`
- `models`
- `helpers`
- `mailers`
- `jobs`
- `services`

It checks that models and services stay away from controller and helper dependencies, and that they do not call controller-only APIs such as `render`, `redirect_to`, `params`, `session`, `cookies`, or `flash`.

Use `architecture :rails_strict` when the app follows Zeitwerk naming and you also want cycle checks across the Rails components.

```ruby
architecture :rails_strict
```
