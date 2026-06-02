---
title: Rules
nav_order: 1
description: The checks ArchSpec can run.
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

ArchSpec reports the rule id, file, line, message, evidence, confidence, and stable id. Use the rule id for suppressions.

## Rule Families

- [Dependencies]({% link _rules/dependencies.md %})
- [Methods]({% link _rules/methods.md %})
- [Protocols]({% link _rules/protocols.md %})
- [Objects]({% link _rules/objects.md %})
- [Constants]({% link _rules/constants.md %})
- [Cycles]({% link _rules/cycles.md %})
- [Zeitwerk Names]({% link _rules/zeitwerk-names.md %})

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
