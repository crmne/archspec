---
title: Vanilla Rails
nav_order: 3
description: Keep behavior on models and forbid extra abstraction directories.
---

# Vanilla Rails

Vanilla Rails is a Rails architecture for rich models and thin controllers,
without service objects, form objects, policy objects, presenters, decorators,
or view components.

```ruby
architecture :vanilla_rails
```

It starts from [Rails]({% link _architectures/rails.md %}), then requires
these directories to stay empty:

- `app/services`
- `app/forms`
- `app/policies`
- `app/decorators`
- `app/presenters`
- `app/components`

See the [Vanilla Rails guide]({% link _guides/vanilla-rails.md %}) for the
reasoning and for project-specific rules you can add on top.
