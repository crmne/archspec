---
title: CLI
nav_order: 2
description: ArchSpec command line reference.
---

# CLI

## init

```sh
bundle exec archspec init
bundle exec archspec init Archspec.rb --force
```

Creates a starter `Archspec.rb`.

## check

```sh
bundle exec archspec check
bundle exec archspec check --config config/architecture.rb
bundle exec archspec check --format json
```

Runs all rules. The command exits non-zero when violations are found.

## baseline

```sh
bundle exec archspec check --update-baseline
```

Writes the current violations to the configured baseline. Use this for existing apps, not for accepting new regressions.

## explain

```sh
bundle exec archspec explain app/models/user.rb
bundle exec archspec explain Billing::Invoice
```

Shows what ArchSpec knows about a file or constant: expected constant, definitions, component assignment reasons, suppressions, and outgoing facts.
