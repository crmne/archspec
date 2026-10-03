---
title: Rails reflection
nav_order: 7
description: Capture what Rails resolved at runtime (association targets, custom validators, and conditional concern effects) as facts that static ArchSpec checks enforce.
---

# Rails reflection

Some dependencies are not spelled out in the source. `belongs_to :customer`
names a class through Rails conventions, `validates :email, email: true` names
`EmailValidator` the same way, and a concern can decide at runtime what it
mixes into a model. ArchSpec can ask your booted application what Rails
actually resolved, save that as facts, and check it statically from then on.

## Capture facts

Add one line to `Archspec.rb`:

```ruby
architecture :rails
reflect :rails
```

Then run:

```sh
bundle exec archspec reflect --environment test
bundle exec archspec check
```

`reflect` starts a separate process, loads `config/environment.rb`, eager loads
the application, and writes `archspec_facts/rails.yml`. Your application must be
able to boot in the chosen environment; the usual boot requirements still
apply. ArchSpec does not run migrations, connect to the database, or query
records.

`check` and `explain` only read the facts. They never load the application or
Rails. `facts "archspec_facts"` without `reflect` also selects the Rails
producer; use it to keep the facts in another directory.

## What the Rails producer records

**Associations.** Each association's resolved target, using the application's
real inflections, namespace lookup, `class_name`, and `through` options, becomes
a reference located at its declaration. Generated readers and writers become
methods on the model. Inherited associations are recorded once, on the model
that declares them; associations declared in concerns belong to each model that
includes the concern, with the location in the concern.

**Custom validators.** `validates :email, email: true` and namespaced keys such
as `"billing/iban": true` become references from the model to the validator
class Rails resolved, at the `validates` call. Validators passed to
`validates_with` are already visible in the source. Active Model and Active
Record's own validators are skipped.

**Conditional concern callbacks.** Static analysis treats a mixin or method
inside a conditional `included` or `prepended` block as a gap, because it
cannot know which branch runs. The producer inspects every consumer: a module
the consumer really received, or a method whose definition is really that
callback's, is recorded on that consumer, located at the declaration. When
every consumer could be inspected and every observed effect had exactly one
possible declaration, the gap is resolved and disappears from the analysis
gaps. Otherwise it stays.

Diagnostics point at the declaration, so suppressions and todo entries work as
they do for source facts. `archspec explain` marks these facts with
`(from rails facts)`.

The producer never guesses. Dynamic association names, ambiguous redeclarations,
polymorphic targets, unresolvable classes, and validators with no literal
declaration are reported as analysis gaps. Polymorphic associations still get
their confirmed readers and writers.

## Keep facts current

Facts describe the source they were captured from. When it changes, `check`
reports a `facts.stale` violation and stops using the affected facts:

- **An edited model or concern.** The facts recorded from that file go stale.
  The Rails producer covers `app/models/**/*.rb` (including engines under
  `*/app/models/`) and every file its facts cite, so adding a model file also
  reports it. Edits anywhere else, such as a controller or a service, do not
  touch the facts. A fact that depends on another file only indirectly, such
  as a `through` association whose intermediate model changed, is caught
  through that model's own stale report.
- **A new includer of a settled concern.** A conditional callback resolved from
  the captured consumers is reported as stale for any class that includes the
  concern later.
- **A deleted file.** Its facts are dropped with it.
- **Configuration or dependencies.** A change to anything under `config/`, the
  `Gemfile` or `Gemfile.lock`, a gemspec, or `.ruby-version` invalidates the
  whole file.
- **A different environment.** The producer records `RAILS_ENV`. When a check
  runs with a different `RAILS_ENV`, the facts are stale.

```text
[error] rails facts are out of date for this file; run `archspec reflect` [facts.stale]

app/models/invoice.rb:1:1
```

A stale fact never passes silently: the check fails until you regenerate.
`--update-todo` refuses to run while facts are stale, and stale violations are
never written to the todo. When you check specific paths, a stale file outside
them is not reported, but stale configuration always is.

Run reflection after changing models or configuration:

```sh
bundle exec archspec reflect --environment test && bundle exec archspec check
```

Environment variables other than `RAILS_ENV`, external services, database-driven
configuration, and path dependencies outside the project are not fingerprinted.
Regenerate when those change too. Facts describe the runtime that produced them,
not every possible configuration.

Commit `archspec_facts/` to keep checks independent of booting Rails, or
regenerate it in a CI step that has the application's dependencies. A failed
reflection keeps the previous file.

## Other frameworks

Any library can supply facts through its own producer, run by the same
`archspec reflect` command. See
[Framework integrations]({% link _guides/framework-integrations.md %}).
