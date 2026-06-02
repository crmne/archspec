---
title: Zeitwerk Names
nav_order: 8
description: Check conventional Rails file-to-constant names.
---

# Zeitwerk Names

Use this rule when the project follows Rails and Zeitwerk naming conventions.

```ruby
verify_zeitwerk_names!
```

Rule id: `zeitwerk.naming`

ArchSpec computes the expected constant from conventional paths:

```text
app/models/user.rb            -> User
app/services/billing/charge.rb -> Billing::Charge
```

It then checks whether the file defines that constant.

Do not use this rule for projects that intentionally keep multiple classes in one file or use custom acronyms that ArchSpec does not know.
