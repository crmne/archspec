---
title: Vanilla Rails
nav_order: 3
description: Use ArchSpec's vanilla Rails preset to keep behavior on models, protect conventional boundaries, and forbid extra abstraction directories.
seo:
  title: Vanilla Rails Architecture
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

It also defines a `views` component for `app/views/**/*.erb` and forbids views
from depending on models. Direct model references such as `<%= User.count %>`
are flagged; calls on controller-provided objects such as `<%= @user.name %>`
are allowed because their receiver types are not inferred.
The `components:` option replaces the default component map, so you can
override the view paths or omit `views` to omit its rule.

See the [Vanilla Rails guide]({% link _guides/vanilla-rails.md %}) for the
reasoning and for project-specific rules you can add on top.
