---
title: Clean
nav_order: 6
description: Enforce the inward dependency rule.
---

# Clean

Clean architecture is modeled as ordered layers:

```ruby
architecture :clean
```

Dependencies move inward:

```text
frameworks -> interface_adapters -> use_cases -> entities
```

This compiles to the same primitive rules as [Layered]({% link _architectures/layered.md %}), with names that match Clean Architecture vocabulary.

The default Rails-flavored directories are:

```ruby
frameworks: %w[app/controllers/**/*.rb app/jobs/**/*.rb app/mailers/**/*.rb]
interface_adapters: %w[app/adapters/**/*.rb app/presenters/**/*.rb app/serializers/**/*.rb]
use_cases: %w[app/use_cases/**/*.rb app/services/**/*.rb]
entities: %w[app/entities/**/*.rb app/domain/**/*.rb app/models/**/*.rb]
```

Pass any of those keys to override the defaults.
