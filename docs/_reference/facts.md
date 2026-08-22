---
title: Facts
nav_order: 3
description: Merge facts a static parse cannot see, such as the classes Active Record associations resolve to, from producer-written files, and write them with reflect.
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
format: 1
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
