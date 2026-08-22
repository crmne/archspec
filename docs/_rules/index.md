---
title: Rules
nav_order: 1
description: Browse every ArchSpec rule for dependencies, cycles, constants, method calls, protocols, object usage, concerns, naming, and component structure.
seo:
  title: Architecture rules overview
permalink: /rules/
---

# Rules

Rules turn an architecture decision into an executable check.

Most rules are scoped to a component:

```ruby
component :models, in: "app/models/**/*.rb"
component :controllers, in: "app/controllers/**/*.rb"

models.cannot_use :controllers
```

ArchSpec reports each violation with its message and rule id, the offending code, and the evidence it found. Use the rule id for suppressions. The JSON format (`--format json`) adds the confidence and the stable id the todo file matches on.

## Rule Families

- [Dependencies]({% link _rules/dependencies.md %})
- [Methods]({% link _rules/methods.md %})
- [Naming]({% link _rules/naming.md %})
- [Protocols]({% link _rules/protocols.md %})
- [Objects]({% link _rules/objects.md %})
- [Constants]({% link _rules/constants.md %})
- [Cycles]({% link _rules/cycles.md %})
- [Components]({% link _rules/components.md %})
- [Concerns]({% link _rules/concerns.md %})

## Reasons, Dates and Actions

Every rule takes `because:`, printed with each finding, and `since:`, a date the rule holds from; findings older than the date are reported but do not fail. Each finding carries the smallest cut the graph can see, or says that it sees none. See [Configuration]({% link _reference/configuration.md %}#reasons-dates-and-actions).

## Suppressing a Rule

Prefer a narrow suppression with a reason:

```ruby
# archspec:disable-next-line dependencies.forbid -- legacy admin export
Admin::UsersController
```

Suppression forms:

```text
archspec:disable-next-line RULE -- reason
archspec:disable-line RULE -- reason
archspec:disable RULE -- reason
archspec:enable RULE
```
