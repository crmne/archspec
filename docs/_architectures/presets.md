---
title: Presets
nav_order: 9
description: Named shortcuts for common Ruby and Rails conventions.
---

# Presets

Presets are shortcuts. They call the same DSL you can write by hand.

## Rails Way

```ruby
preset :rails_way
```

Defines the [Rails MVC]({% link _architectures/rails-mvc.md %}) architecture.

## Rails Strict

```ruby
preset :rails_strict
```

Runs `rails_way`, verifies conventional file names, and checks cycles across Rails components.

## Vanilla Rails

```ruby
preset :vanilla_rails
```

Runs `rails_way`, then forbids the abstraction-layer directories that
37signals-style Rails does without: `app/services`, `app/forms`,
`app/policies`, `app/decorators`, `app/presenters`, and `app/components`
must all stay empty. Behavior belongs on models.

See the [Vanilla Rails guide]({% link _guides/vanilla-rails.md %}) for the
reasoning and for the rules you can add on top.

## Rails Architectures

```ruby
preset :rails_layered
preset :rails_hexagonal
preset :rails_clean
preset :rails_cqrs
preset :rails_event_driven
```

These use the default Rails paths for the matching architecture.

They are starting points. Add project-specific rules beside them.
