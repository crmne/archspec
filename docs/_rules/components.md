---
title: Components
nav_order: 8
description: Use ArchSpec component rules to require selected directories to stay empty and report files that violate an intentional project boundary.
---

# Components

Use this rule when the architecture decision is "this kind of code should not exist here at all."

```ruby
component(:services, in: "app/services/**/*.rb")
  .must_be_empty(because: "behavior belongs on models")
```

Rule id: `components.empty`

Every file that lands in the component fails the check:

```text
[error] services must stay empty: behavior belongs on models [components.empty]

app/services/create_user.rb:1:1

  → 1 │ class CreateUser
      │ ^
    2 │   def perform

  note: app/services/create_user.rb belongs to services
```

The `because:` reason is optional but recommended. It appears in the failure
message and tells the reader where the code should go instead.

## When To Use It

Use it when a convention bans a whole category of objects. Vanilla Rails in
the 37signals style has no service objects, form objects, or policy objects;
`architecture :vanilla_rails` uses this rule for those directories. See the
[Vanilla Rails guide]({% link _guides/vanilla-rails.md %}).

It also helps during migrations: once a legacy directory has been emptied,
`must_be_empty` keeps it empty.
