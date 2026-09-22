---
title: CLI
nav_order: 2
description: Reference every ArchSpec command-line option for checking projects, explaining files, emitting JSON, managing baselines, and choosing config files.
seo:
  title: ArchSpec command-line interface
---

# CLI

Show general or command-specific help without running a check:

```sh
bundle exec archspec help
bundle exec archspec help check
bundle exec archspec check --help
```

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

Each violation prints as a diagnostic block: the message and rule id, the offending code with the exact span underlined, and the evidence ArchSpec found as a note. On a terminal the output is colored; set `NO_COLOR` to disable.

```text
[error] models must not depend on controllers [dependencies.forbid]

app/models/user.rb:9:5

     8 │   def controller_peek
  →  9 │     UsersController
       │     ^~~~~~~~~~~~~~~
    10 │   end

  note: User references UsersController

1 architecture violation found.
```

A clean run prints one line:

```text
ArchSpec passed: 391 files, 407 constants, 11061 facts checked.
```

Pass paths to report only violations in those files or directories. ArchSpec still analyzes the whole project, so cross-file dependencies resolve, but output is scoped to what you touched:

```sh
bundle exec archspec check app/models/user.rb app/services
```

This is the fast loop after an agent or a person edits a few files. It cannot be combined with `--update-todo`.

## todo

```sh
bundle exec archspec check --update-todo
```

Writes the current violations to the configured todo file. Use this for existing apps, not for accepting new regressions. Parse errors are never written to the todo; a file that does not parse has to be fixed.

Each entry records the violation's stable id and the fields the id is built from: rule, path, message, and evidence. Line numbers are left out on purpose. They are not part of the id, so an edit that only shifts code leaves the file byte-identical, and entries sort by those same fields rather than by location.

```sh
bundle exec archspec check --check-todo
```

Runs the normal check and additionally fails when the todo lists an entry that no current violation matches, because the violation was fixed or is now suppressed locally. These are exactly the entries `--update-todo` would drop, so a fixed violation cannot linger in the burn-down list. Obsolete entries are printed before the verdict; with `--format json` they appear under `obsolete_todo`. With path arguments, only entries under those paths are reported. The configured todo file has to exist. Use this in CI instead of regenerating the file and diffing it. It cannot be combined with `--update-todo`.

## reflect

```sh
bundle exec archspec reflect --environment test
bundle exec archspec reflect --config config/architecture.rb --environment test
```

Requires `facts "archspec_facts"` in the architecture configuration. This is an
explicit runtime command: it runs `bin/rails runner`, eager loads the application,
and writes resolved Active Record associations to `archspec_facts/rails.yml`.
The default environment is `RAILS_ENV`, or `development` when unset.

Regenerate after source, configuration, or dependency changes. Failed reflection
preserves the previous snapshot. Polymorphic, unresolved, and ambiguous
associations are reported as analysis gaps. See
[Association reflection]({% link _guides/association-reflection.md %}) for the
format, staleness contract, and custom producers.

## explain

```sh
bundle exec archspec explain app/models/user.rb
bundle exec archspec explain Billing::Invoice
```

Shows what ArchSpec knows about a file or constant: defined constants,
component assignment reasons, suppressions, resolved ancestry, outgoing facts,
incoming dependencies, and analysis gaps.

```text
app/models/user.rb

  defined constants: User
  components:
    models: matched file pattern app/models/**/*.rb
  suppressions:
    2-3 │ dependencies.forbid -- migrating legacy coupling
  outgoing facts:
    1:14 │ inherits from ApplicationRecord
     2:3 │ calls has_many
     9:5 │ references UsersController
  incoming dependencies:
    4:7 │ references User
  analysis gaps: 1 unknown receiver
```

Explaining a constant shows where it is defined, its components, its superclass, and its methods:

```text
User

  kind: class
  file: app/models/user.rb:1
  components:
    models: defined in matched file
  superclass: ApplicationRecord
  resolved ancestors: ApplicationRecord
  unresolved ancestors: ActiveRecord::Base
  instance methods: controller_peek, summary
  class methods: find_active
  outgoing facts:
    1:14 │ inherits from ApplicationRecord
  incoming dependencies: (none)
  analysis gaps: (none)
```
