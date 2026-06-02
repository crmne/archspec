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

- [Dependencies](/rules/dependencies/)
- [Methods](/rules/methods/)
- [Protocols](/rules/protocols/)
- [Objects](/rules/objects/)
- [Constants](/rules/constants/)
- [Cycles](/rules/cycles/)
- [Zeitwerk Names](/rules/zeitwerk-names/)

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
