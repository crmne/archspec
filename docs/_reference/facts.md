---
title: Facts
nav_order: 3
description: Merge facts a static parse cannot see, from association targets to ancestry and typed calls, out of producer-written files, and write them with reflect.
seo:
  title: ArchSpec facts files and archspec reflect
---

# Facts

`belongs_to :session` is a dependency on `Session`, but no constant appears in the source, so a static parse cannot see it. ArchSpec does not guess with inflectors or `class_name:` heuristics; a half-right edge is worse than none in a tool that otherwise only states facts. Instead, a producer that knows the answer writes it to a facts file, and `check` merges the file before rules run.

```ruby
facts "archspec_facts"
```
{: data-title="Archspec.rb"}

The directory defaults to `archspec_facts/`. `check` stays fully static: it reads every `*.yml` in the directory, adds each reference as a dependency edge and each generated method onto its owner, and then runs the rules exactly as before. Every rule sees association targets, and a bare call to an association reader counts as the component's own API.

## The file

```yaml
format: 2
producer: archspec-reflect
producer_version: 1.0.1
commit: 3f2a9c1d4e5b6a7c8d9e0f1a2b3c4d5e6f7a8b9c
dirty: false
references:
  - owner: User
    file: app/models/user.rb
    line: 3
    target: Session
    macro: belongs_to
    name: session
    determination: reflected
generated_methods:
  - owner: User
    names: [session, session=, build_session, create_session, create_session!, reload_session]
misses:
  polymorphic: 2
```
{: data-title="archspec_facts/rails.yml"}

Two entry types: a constant at a file and line references another constant, and a constant has generated methods. A reference may say how its target was determined (`reflected`, `declared`, `through`, `index`), which the producers that ship with ArchSpec always do. Any gem with its own macros can write its own file into the directory without ArchSpec knowing the DSL; the producer name and version say where each file came from, and the commit says which tree it describes. Keep the directory fresh the way you keep the todo file fresh.

A file that states something ArchSpec does not understand is an error naming the file and the entry, never a silent skip: an unknown key, an unknown field on an entry, or a format other than `1`. A target the parser never defined stays an unresolved name, exactly like a constant from a gem, and lands in no component. Misses are counted by cause so the file states what it could not say.

## What check reports

Every run ends by naming the files it merged, or saying the directory was absent, so a run without facts never reads like a run that agreed:

```text
ArchSpec passed: 391 files, 407 constants, 11061 facts checked.
facts: archspec_facts/rails.yml (archspec-reflect 1.0.1, 214 entries)
```

```text
facts: none (archspec_facts/ absent)
```

A violation whose evidence came from a file says so in its note:

```text
  note: User references Session (from archspec_facts/rails.yml)
```

The JSON format carries the same under `facts_files`, with the producer, commit, entry count and misses per file.

## Associations without booting

```ruby
facts "archspec_facts", associations: :static
```
{: data-title="Archspec.rb"}

Most association targets can be stated from the source alone, and `check` can merge them on every run without a boot. An association becomes a reference in three determinations and no fourth. `declared`: `class_name:` is a string or symbol literal, resolved the way the parser resolves any constant from the declaring class. `through`: `through:` is walked into the intermediate model's own declaration hop by hop, each hop resolved by these same rules, until a target is reached; a chain that meets itself again is a miss. `index`: the bare name is matched against the models the application declares, built from the classes whose ancestry reaches `ApplicationRecord` or `ActiveRecord::Base`, subclasses included, with the declaring class's own namespace tried first, then each enclosing one, and exactly one match required. A collection name matches a model only through the three spellings `s`, `es` and `ies`; `people` matches no model and is a miss.

Nothing else becomes an edge. Polymorphic associations, `source_type:`, a `class_name:` that is not a literal, an association declared in a concern or an abstract class, a subclass restating an inherited association, a name that matches no declared model or more than one, and a `through:` whose intermediate or source does not resolve are counted by cause and reported in the summary. A collection name is matched by a lookup over the declared model names with three plural spellings (`s`, `es`, `ies`) and no irregulars; nothing guesses a name the application does not declare. Files end in `.yml` or `.yaml`.

```sh
bundle exec archspec reflect --static
```

The same facts can be written to `archspec_facts/associations.yml` instead of merged on the fly, with the producer name `archspec-associations`, a `determination` on every reference, and the misses by cause, so the file can be reviewed and committed like any other. Where a booted `reflect` file exists it says more; the static file costs nothing and needs nothing.

## reflect

```sh
bundle exec archspec reflect
bundle exec archspec reflect --output archspec_facts/rails.yml
```

The one ArchSpec command that boots the application. It runs through `bin/rails runner`, eager-loads, asks every Active Record model for `reflect_on_all_associations`, and writes `archspec_facts/rails.yml` with the real resolved class names. Polymorphic associations and reflections that raise are counted as misses, not guessed. The output is sorted and carries no timestamps, so two runs on the same tree write the same file. Run it when associations change, commit the file, and `check` keeps working without booting anything.

## Ancestry, definitions and calls

Format 2 adds three lists a producer can state beside references and generated methods, each entry naming the producer's determination the way a reference does:

```yaml
ancestry:
  - owner: Invoice
    kind: inherits
    target: Billing::Document
    file: app/models/invoice.rb
    line: 1
    determination: rubydex-workspace
definitions:
  - owner: Invoice
    name: total
    scope: instance
    visibility: public
    file: app/models/invoice.rb
    line: 9
    determination: rubydex-workspace
calls:
  - owner: Billing::Report
    file: app/services/billing/report.rb
    line: 14
    method: destroy_all
    receiver: Invoice
    determination: rubydex-workspace
```

`check` merges them as the facts the parser would have produced. An `inherits` entry becomes an `inherits_from` edge and the owner's superclass, a mixin entry (`includes`, `prepends`, `extends`) the matching edge and mixin, so `no_cycles`, `cannot_reference_includers` and the ancestry walk behind `must_implement` see them. A definition becomes an instance or class method with its visibility, so protocols and the own-API exemption see it. A call becomes a `calls_named_method` edge whose receiver is the named constant, so `cannot_call` sees a typed call the parser recorded with an untyped receiver.

The parser is never overridden. An entry the parser already had is counted as `already_resolved` for that file and left alone; an `inherits` entry that contradicts the superclass the parser read is counted as `conflict` and left alone. Both counts print in the facts line and in the JSON `facts_files` and `census.facts_entries`, per file and per entry type, so a file that added nothing reads differently from a file that was not read.

Format 1 files keep loading, with the three lists empty. Every producer ArchSpec ships writes format 2: `reflect` still states references and generated methods only, the static association producer adds the `inherits` chain it walked to `ApplicationRecord` with determination `index`, and the Rubydex producer writes all three lists under the rule below.

## Constants through Rubydex

```sh
bundle exec archspec reflect --rubydex
```

A second resolver for the same file format. [Rubydex](https://github.com/Shopify/rubydex) indexes the workspace and its locked bundle, so it resolves what the parser's lexical lookup cannot: a constant defined in a gem, or reached through a superclass or an included module. The producer writes `archspec_facts/rubydex.yml` with only those references, each marked `rubydex-workspace` when the target is defined under the root and `rubydex-gem` when it is not. A reference the parser already resolved is counted as `already_resolved` and not written, so no edge appears twice; one the two resolvers disagree on is counted as `disagreed` and left out. The other counts are `unresolved` (Rubydex found no declaration), `self` (`self` inside a class), `declaration` (the name a `class` line defines), `outside_source` (a file the architecture file does not analyze) and `diagnostic`.

Under the same rule the producer writes what else Rubydex resolved and the parser did not: a superclass or mixin the parser has none for (`extend self` is the common case), a method the parser did not see defined, and a call whose receiver Rubydex resolved to a constant where the parser saw a variable. A call the parser recorded as implicit self is counted as `call_implicit_self`, not written, since the enclosing class is not a receiver the parser lacked.

The gem is required only by this command: add `rubydex` to the development group and run under `bundle exec`. Without the gem, a `Gemfile` or a `Gemfile.lock` the command refuses rather than indexing the workspace alone. References into gems reach `check` as names the tree does not define, which is how gem constants already behave: `cannot_reference_constants` sees them and component rules do not.

## A second resolver inside check

```ruby
resolver :rubydex
```
{: data-title="Archspec.rb"}

The same resolution, run on every check instead of written once. With the declaration, `check` indexes the workspace and the locked bundle through Rubydex after reading the files, builds the facts file above in memory and merges it, and keeps every answer Rubydex gave beside the parser's own. On each constant reference the two converge: both naming the same constant is an edge marked `converged`; a reference only the parser resolved keeps its edge; one only Rubydex resolved is an edge marked `rubydex`; a reference the two resolve to different constants is no edge, counted as a disagreement in the census, and doubts every finding in that constant to medium confidence with both answers in the note. Neither resolver outranks the other, and a target defined in a gem still reaches the rules as a name the tree does not define.

The summary prints one line per resolver, `resolvers: rubydex: converged 412, parser only 3, rubydex only 29, disagreed 0 (index hit, 0.08s)`, and `explain` prints both answers on every edge. The index is kept under `.archspec/resolvers/` as one Marshal payload, keyed by the content of `Gemfile.lock`, the parsed files, the archspec and Rubydex versions, and the content of any gem the lockfile points at a path; a check on an unchanged tree and bundle reads it, and a payload from another tree or bundle is removed when a new one is written. Rubydex resolves across files, so any edit to a Ruby file indexes the workspace again: the warm path is an unchanged tree, and on a large application a cold index costs many times a plain check, which the resolver line states as it is. `check` loads that payload, and the snapshot's, from `.archspec/`, a directory the tool writes and ignores itself. `archspec reflect --rubydex` is the same computation followed by a write, so the file it leaves in `archspec_facts/` and the facts a declared resolver merges are one and the same; declare the resolver or write the file, not both, or the references land twice.

The gem stays out of the gemspec: it loads only when the resolver is declared or the command runs. A declared resolver whose gem, `Gemfile` or `Gemfile.lock` is missing fails the check by name, never silently, because two machines grading the same tree differently and both reading clean is the failure the declaration exists to prevent.
