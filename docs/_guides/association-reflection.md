---
title: Association reflection
nav_order: 7
description: Capture resolved Active Record associations as versioned facts, then enforce their dependencies with static ArchSpec checks.
---

# Association reflection

An association such as `belongs_to :customer` refers to a class without naming a
Ruby constant in the source. ArchSpec can capture that dependency using your
application's real Active Record reflections, including its inflectors,
namespace lookup, `class_name`, and `through` associations.

## Capture associations

Add a facts directory to `Archspec.rb`:

```ruby
architecture :rails
facts "archspec_facts"
```

Then run:

```sh
bundle exec archspec reflect --environment test
bundle exec archspec check
```

`reflect` explicitly starts `bin/rails runner`, eager loads the application, and
asks Active Record for its resolved associations. It writes
`archspec_facts/rails.yml` atomically. Your application must be able to boot in the
chosen environment; any normal boot requirements still apply. ArchSpec does not
run migrations or query association records.

`check` and `explain` only read the facts files. They do not require Active Record
or load the application. Captured references participate in dependency, privacy,
and cycle rules, with diagnostics pointing at the association declaration.
Generated association readers and writers also contribute method facts.

The reflector records inherited associations once, on their declaring model. It
can locate declarations in ordinary model bodies and included concerns. An
association needs one matching literal declaration to produce a source-backed
reference. Dynamic names and ambiguous redeclarations are reported as gaps.
Polymorphic associations have no single target class and remain gaps too; their
confirmed generated readers and writers can still be recorded.

## Keep snapshots current

Each facts file records content hashes for every analyzed source file, plus Rails
configuration files under `config/`, the root Gemfile, lockfile, gemspecs, and Ruby
version file when present. Configured facts directories are excluded from these
hashes. A changed, added, or deleted input invalidates the snapshot. Missing or
stale configured facts fail the check with a regeneration message.

Run reflection after code, dependency, or configuration changes, before checking:

```sh
bundle exec archspec reflect --environment test
bundle exec archspec check --format json
```

Capture a consistent environment. The snapshot records its Rails environment;
when `RAILS_ENV` is set during a check, it must match. Environment variables,
external services, database-driven configuration, and local path dependencies
outside the analyzed project are not fingerprinted. Regenerate when those change
as well. A snapshot describes the runtime that produced it, not every possible
runtime configuration.

You can commit snapshots to make static checks independent of Rails booting, or
regenerate them in a CI setup step that has the application's dependencies.
Remove the `facts` declaration to opt out entirely. A failed reflection run keeps
the previous file, which must still pass the staleness check before use.

## Custom facts producers

The facts format also accepts output from other frameworks and macro libraries.
See [Framework integrations]({% link _guides/framework-integrations.md %}) for a
producer example, the versioned contract, and the relationship between static
concern modeling and runtime reflection. The built-in Rails producer currently
captures associations; it does not capture validators or arbitrary callback
effects.
