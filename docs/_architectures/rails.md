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

Some apps share helper modules as plain utilities outside views. Allow that with `share_helpers`, which drops the models-and-services to helpers boundary while keeping the rest:

```ruby
architecture :rails, share_helpers: true
```

Override the controller API list when a component legitimately defines one of those names, such as a service framework with its own `params`:

```ruby
architecture :rails, controller_api: %i[render redirect_to session cookies flash]
```

## Strict

`rails_strict` adds a cycle check across the Rails components and a concern independence check on `app/**/concerns/**/*.rb`.

```ruby
architecture :rails_strict
```

Point the concern check elsewhere with `concerns:`, or turn it off with `concerns: false`:

```ruby
architecture :rails_strict, concerns: "app/models/concerns/**/*.rb"
```
