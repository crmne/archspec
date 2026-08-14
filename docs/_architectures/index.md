---
title: Architectures
nav_order: 1
description: Explore ArchSpec architecture presets for Rails, layered, hexagonal, clean, modular monolith, CQRS, event-driven, and Ruby conventions.
permalink: /architectures/
---

# Architectures

Architectures are rule bundles.

They define conventional components and apply dependency rules between them. They do not add a second analysis engine.

`preset` is an alias for `architecture`. Use whichever word fits: `architecture :rails` for a structural bundle, `preset :ruby_conventions` for a convention pack.

Available architectures:

- [Rails]({% link _architectures/rails.md %})
- [Vanilla Rails]({% link _architectures/vanilla-rails.md %})
- [Layered]({% link _architectures/layered.md %})
- [Hexagonal]({% link _architectures/hexagonal.md %})
- [Clean]({% link _architectures/clean.md %})
- [Modular Monolith]({% link _architectures/modular-monolith.md %})
- [CQRS]({% link _architectures/cqrs.md %})
- [Event Driven]({% link _architectures/event-driven.md %})
- [Ruby Conventions]({% link _architectures/ruby_conventions.md %})

Use an architecture when your app already follows a clear folder or namespace convention. Use primitive [rules]({% link _rules/index.md %}) when the shape is custom.
