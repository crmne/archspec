---
title: Vanilla Rails
nav_order: 4
description: Turn 37signals-style Rails conventions into executable checks.
---

# Vanilla Rails

After reading this guide, you will know:

- What vanilla Rails means as an architecture.
- What `preset :vanilla_rails` checks.
- Which conventions ArchSpec cannot check.

## The Architecture

37signals builds Basecamp and HEY with rich models and thin controllers, and
without the layers many Rails shops add on top: no service objects, no form
objects, no policy objects, no presenters. Business logic lives on models.
Plain Ruby objects live in `app/models` next to them.

Jorge Manrubia describes the approach in
[Vanilla Rails is plenty](https://dev.37signals.com/vanilla-rails-is-plenty/).
The [37signals-skills](https://github.com/marckohlbrugge/37signals-skills)
project collects these conventions as instructions for AI coding agents.
Instructions only cover code generation. ArchSpec checks the code afterwards.

## The Preset

```ruby
ArchSpec.define "Application architecture" do
  preset :vanilla_rails
end
```
{: data-title="Archspec.rb"}

This runs the [Rails MVC]({% link _architectures/rails-mvc.md %}) checks,
then requires these directories to stay empty, using the
[components rule]({% link _rules/components.md %}):

| Directory        | Reason                                          |
| ---------------- | ----------------------------------------------- |
| `app/services`   | behavior belongs on models, not service objects |
| `app/forms`      | use strong parameters and model validations     |
| `app/policies`   | authorization is predicate methods on models    |
| `app/decorators` | use helpers and partials                        |
| `app/presenters` | presentation objects are POROs in `app/models`  |
| `app/components` | use helpers and ERB partials                    |

If a change adds `app/services/create_user.rb`, the check fails:

```text
[components.empty] app/services/create_user.rb:1:1
  services must stay empty: behavior belongs on models, not service objects
  evidence: app/services/create_user.rb belongs to services
```

## More Rules

These conventions from the same playbook are also checkable. Add the ones
your app follows.

Jobs receive context as arguments instead of reading `Current` inside
`perform`:

```ruby
component :jobs, in: "app/jobs/**/*.rb"
jobs.cannot_reference_constants "Current"
```

The same controllers serve HTML and JSON, so there is no API namespace:

```ruby
component(:api_controllers, in: "app/controllers/api/**/*.rb")
  .must_be_empty(because: "the same controllers serve HTML and JSON via respond_to")
```

Conventional file names define conventional constants:

```ruby
verify_zeitwerk_names!
```

## What ArchSpec Cannot Check

Some vanilla Rails conventions are about design judgment, not file
structure. ArchSpec does not check:

- CRUD-only routing (`resource :closure` instead of `post :close`)
- Concern size and cohesion
- State as records instead of booleans (a `Closure` model vs `closed: true`)
- Helpers taking explicit arguments instead of reading instance variables
- Jobs being one-line delegations to model methods
- Minitest and fixtures over RSpec and factories

Use code review and agent instructions for these.
