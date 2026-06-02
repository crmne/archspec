---
title: Clean
nav_order: 5
description: Enforce the inward dependency rule.
---

# Clean

Clean architecture is modeled as ordered layers:

```ruby
architecture :clean,
  frameworks: "app/controllers/**/*.rb",
  interface_adapters: "app/adapters/**/*.rb",
  use_cases: "app/use_cases/**/*.rb",
  entities: "app/entities/**/*.rb"
```

Dependencies move inward:

```text
frameworks -> interface_adapters -> use_cases -> entities
```

This compiles to the same primitive rules as [Layered](/architectures/layered/), with names that match Clean Architecture vocabulary.

Use the Rails defaults with:

```ruby
preset :rails_clean
```
