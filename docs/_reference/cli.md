---
title: CLI
nav_order: 2
description: Every ArchSpec command-line option for checking projects, taking snapshots, grading changes against a baseline, explaining files, and reflecting facts.
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

With paths, only violations in those files are reported. When a snapshot taken under the same version and patterns exists in `.archspec/` with its binary payload, a path-scoped run re-reads the named paths and takes every other file's facts from the snapshot, so the loop after an edit costs the edit, not the tree; a snapshot with only its YAML graph is reused when the definition declares a `cache`, and otherwise every file is read as before. See [Baseline]({% link _reference/baseline.md %}) for taking a snapshot and [Configuration]({% link _reference/configuration.md %}) for the cache.

Each violation prints as a diagnostic block: the message and rule id, the offending code with the exact span underlined, and the evidence ArchSpec found as a note. On a terminal the output is colored; set `NO_COLOR` to disable.

```text
[error] models must not depend on controllers [dependencies.forbid]

app/models/user.rb:9:5

     8 │   def controller_peek
  →  9 │     UsersController
       │     ^~~~~~~~~~~~~~~
    10 │   end

  note: User references UsersController
  reason: models and services run outside a request too, so nothing in them may know the controller
  action: move User to services, where its other dependencies already land

1 architecture violation found.
```

The note is the evidence, the reason is the rule's `because:`, and the action is the smallest cut the graph can see. Findings on lines older than a rule's `since:` date are listed under their own heading after the failing ones and do not affect the exit status; when a line could not be dated, the run says so once and the finding counts as undated.

A clean run prints the summary, names the facts files it merged or says the directory was absent, and then says what the analysis could not see:

```text
ArchSpec passed: 391 files, 407 constants, 11061 facts checked.
facts: none (archspec_facts/ absent)
could not see: 312 unresolved constant references, 14 dynamic features, 2 unused suppressions
```

The last line is the census: constant references that matched no definition in the project (gems and the standard library land here), dynamic features such as `send` and `const_get`, calls whose receiver the parser cannot type, files ignored by glob or unreadable by the parser, suppressions that matched nothing, and todo entries that matched nothing. It prints on passing and failing runs alike, and reads `could not see: nothing` only when every count is zero, so a run the parser barely read never looks like one it read in full. The JSON format carries the same counts as a `census` object, with the unresolved names and the constants carrying each dynamic feature.

A diagnostic inside a constant that uses a dynamic feature is reported at medium confidence, and its note names the feature and line, because the feature may define or reach what the rule could not see. The scope is the constant, not the file.

Unused suppressions and stale todo entries are counted but never fail a run by themselves. Ask for them:

```sh
bundle exec archspec check --housekeeping
```

reports each as a diagnostic under `housekeeping.unused_suppression` or `housekeeping.stale_todo` and exits non-zero when any exist. It cannot be combined with `--update-todo`.

Pass paths to report only violations in those files or directories. ArchSpec still analyzes the whole project, so cross-file dependencies resolve, but output is scoped to what you touched:

```sh
bundle exec archspec check app/models/user.rb app/services
```

This is the fast loop after an agent or a person edits a few files. It cannot be combined with `--update-todo`.

## snapshot

```sh
bundle exec archspec snapshot
bundle exec archspec snapshot --output tmp/archspec-before
```

Writes the analysed graph and a receipt under `.archspec/` so a later check has a before to grade against. See [Baseline]({% link _reference/baseline.md %}).

## check --baseline

```sh
bundle exec archspec check --baseline
bundle exec archspec check --baseline --mode strict
bundle exec archspec check app/models --baseline tmp/archspec-before
```

Grades the change against the snapshot instead of failing the tree: what it introduced, resolved, or declared. Exits `1` when the mode fails the change, `3` when the snapshot is not comparable and nothing was graded. See [Baseline]({% link _reference/baseline.md %}).

## todo

```sh
bundle exec archspec check --update-todo
```

Writes the current violations to the configured todo file. Use this for existing apps, not for accepting new regressions. Parse errors are never written to the todo; a file that does not parse has to be fixed.

## reflect

```sh
bundle exec archspec reflect
bundle exec archspec reflect --output archspec_facts/rails.yml
```

Boots the application through `bin/rails runner` and writes the Active Record associations, with their resolved classes, to the facts directory. This is the only command that loads the app; `check` merges the file it writes and stays static. See [Facts]({% link _reference/facts.md %}).

```sh
bundle exec archspec reflect --rubydex
```

Writes `archspec_facts/rubydex.yml` with the constant references Rubydex resolves and the parser cannot, without booting. Needs the `rubydex` gem in the bundle; nothing else loads it.

## explain

```sh
bundle exec archspec explain app/models/user.rb
bundle exec archspec explain Billing::Invoice
```

Shows what ArchSpec knows about a file or constant: defined constants, component assignment reasons, suppressions, and outgoing facts.

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
```

Explaining a constant shows where it is defined, its components, its superclass, and its methods:

```text
User

  kind: class
  file: app/models/user.rb:1
  components:
    models: defined in matched file
  superclass: ApplicationRecord
  instance methods: controller_peek, summary
  class methods: find_active
```
