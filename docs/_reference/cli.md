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

Pass paths to report only violations in those files or directories. ArchSpec still analyzes the whole project, so cross-file dependencies resolve, but output is scoped to what you touched:

```sh
bundle exec archspec check app/models/user.rb app/services
```

This is the fast loop after an agent or a person edits a few files. It cannot be combined with `--update-todo`.

## todo

```sh
bundle exec archspec check --update-todo
```

Writes the current violations to the configured todo file. Use this for existing apps, not for accepting new regressions.

## explain

```sh
bundle exec archspec explain app/models/user.rb
bundle exec archspec explain Billing::Invoice
```

Shows what ArchSpec knows about a file or constant: defined constants, component assignment reasons, suppressions, and outgoing facts.
