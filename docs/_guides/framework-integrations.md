---
title: Framework integrations
nav_order: 6
description: Teach ArchSpec what a framework or macro library does at runtime with a small facts producer that archspec reflect runs and checks read as data.
---

# Framework integrations

Frameworks create dependencies and methods that source code only implies. A
macro such as `uses :billing` may resolve `BillingService` by convention and
define a `billing` method. ArchSpec cannot see that statically, so a
**producer** observes it in the booted application and records it as facts.
Checks then enforce those facts without booting anything.

```text
archspec reflect:  boot -> analyze source -> producer records facts -> archspec_facts/<name>.yml
archspec check:    analyze source -> apply fresh facts -> rules
```

ArchSpec ships the [Rails producer]({% link _guides/association-reflection.md %}).
This guide shows how to write your own.

## Write a producer

A producer is a name and a block. This one teaches ArchSpec about the `uses`
macro above:

```ruby
# lib/archspec/widgets_facts.rb
ArchSpec.producer :widgets do
  sources "app/widgets/**/*.rb"

  boot do |root|
    require File.join(root, "config/environment")
  end

  capture do |facts|
    Widgets.registry.each do |widget, (name, service, site)|
      facts.reference(source: widget, target: service, location: site)
      facts.methods(owner: widget, names: name, location: site)
    end
  end
end
```

Declare it in `Archspec.rb`, next to any other producers:

```ruby
reflect :rails
reflect :widgets, require: "./lib/archspec/widgets_facts"
```

A `require:` path that starts with a dot is relative to `Archspec.rb`; anything
else is required from the load path, so a gem can ship its producer. The file
is only loaded by `archspec reflect`, never by `check`.

```sh
bundle exec archspec reflect
```

```text
Updated archspec_facts/rails.yml: 193 references, 404 methods, 11 gaps, 2 resolved gaps (1.2s)
Updated archspec_facts/widgets.yml: 1 reference, 1 method (0.4s)
```

Each producer runs in its own process, all of them in parallel, and writes its
own file. Pass names to run only some: `archspec reflect widgets`. A failing
producer reports its error, keeps its previous file, and does not stop the
others.

```text
[error] widgets must not depend on services [dependencies.forbid]

app/widgets/report.rb:3:3

    2 │   include Widgets
  → 3 │   uses :billing
      │   ^~~~~~~~~~~~~

  note: Report references BillingService
```

### Producer options

| Option | Effect |
| --- | --- |
| `boot { \|root\| ... }` | Loads the framework. Runs before the source is analyzed. |
| `capture { \|facts\| ... }` | Records facts through the builder. Required. |
| `sources "glob", ...` | Analyzed files the producer inspects. Editing or adding one makes only its facts stale; removing one drops its facts. Files the facts cite are always covered. |
| `inputs "glob", ...` | Other files whose change makes the whole document stale. Defaults to `config/**/*.{rb,yml,yaml}`, `Gemfile`, `Gemfile.lock`, `*.gemspec`, and `.ruby-version`. |
| `env "NAME", ...` | Environment variables recorded when captured. A check that sets one to a different value treats the document as stale. Values are stored in plain text, so never name secrets. |

`boot` and `capture` run with the producer as `self`. The block form with an
argument, `ArchSpec.producer(:widgets) { |producer| producer.sources ... }`, also
works.

## Record facts

`capture` receives a `ArchSpec::Facts::Builder`. `facts.graph` is the analyzed
source, the same graph checks see.

Owners, sources, and targets can be the runtime class or module itself, its
name, or a graph node. Locations can be a `[path, line]` pair (what
`const_source_location` returns), a backtrace location recorded with
`caller_locations`, anything with a `source_location`, or an
`ArchSpec::SourceLocation`. A line location underlines the code on that line.

| Method | Records |
| --- | --- |
| `reference(source:, target:, location:)` | A dependency from `source` on `target` |
| `methods(owner:, names:, location:)` | Methods on `owner`; optional `scope:` (`:instance` or `:class`), `visibility:`, `signatures:`, `alias_target:`, `mode:`, `installation:` |
| `mixin(owner:, target:, kind:, location:)` | `include`, `prepend`, `extend`, or `singleton_prepend`, with its dependency |
| `gap(source:, message:, location:)` | Behavior the producer could not establish, shown in analysis gaps |
| `resolve(source:, location:, message: nil, consumers: nil)` | Settles an existing static analysis gap at exactly that location; with `consumers:`, only for the includers you inspected |
| `method_definition(owner:, definition:, installation: nil)` | Copies a graph method definition with its metadata |
| `bind_receiver(edge:, receiver:, scope:)` | Resolves an existing receiverless call to a consumer |
| `expose_methods(source:, owner:, scope:)` | Classifies a module's methods as another constant's API |

The source and owner must be analyzed constants. A target can be anything,
but component rules only apply to analyzed targets. A name defined in several
files is ambiguous; pass the graph node in that case.

Record only what the runtime confirms. When evidence cannot pin down a single
declaration or target, record a `gap` at the owner rather than choosing a
plausible answer from naming conventions.

## Freshness

Every document fingerprints its inputs, the analyzed files its `sources`
cover, and every file its facts cite. `check` compares them with the current
files:

- A changed global input, or a mismatched `env` value, makes the whole document
  stale.
- A changed or added covered source file makes only the facts citing it stale.
- A removed file takes the facts citing it with it; there is nothing left for
  them to describe.
- A resolution recorded with `consumers:` is reported as stale for any class
  that includes the module after the capture.

Stale facts are skipped and reported as `facts.stale` violations, so a stale
check fails instead of passing on outdated evidence. The
[Rails guide]({% link _guides/association-reflection.md %}#keep-facts-current)
shows what that looks like.

## How facts combine with source analysis

Facts are added to the same graph as source facts, before components are
assigned, so every rule treats them alike.

- References and mixins are deduplicated against the existing edges.
- Methods follow their `mode`: `if_missing` (the default) keeps an existing
  definition with the same name and scope, `append` adds another definition,
  and `define` replaces earlier definitions, except a later definition in the
  owner's own file.
- Receiver bindings for one call are combined across documents and replace
  that call's previous interpretation after all methods and mixins are applied.
- Conflicting method exposures for one module are rejected.
- A `resolve` removes the matching static gap. Nothing else removes a gap:
  facts that happen to cover the same code leave it in place.

Every document is validated before any fact is applied. An invalid document
fails the check with a message naming the file and the problem.

Facts about constants that exist only at runtime, such as classes created with
`Class.new` or `const_set`, are not supported: every owner and source must be
declared in analyzed source. Record a gap at the code that creates them.

## The facts file

Producers write version 2 documents. You rarely need to read them, but the
format is stable and plain YAML:

```yaml
version: 2
producer: widgets
env: {}
inputs: ["config/**/*.{rb,yml,yaml}", Gemfile, Gemfile.lock, "*.gemspec", .ruby-version]
sources: ["app/widgets/**/*.rb"]
snapshot:
  app/widgets/report.rb: 3f2a...
references:
- {path: app/widgets/report.rb, line: 3, column: 3, end_line: 3, end_column: 16,
   source_path: app/widgets/report.rb, source: Report, target: BillingService}
methods:
- {path: app/widgets/report.rb, line: 3, column: 3, end_line: 3, end_column: 16,
   source_path: app/widgets/report.rb, owner: Report, names: [billing],
   scope: instance, visibility: public, mode: if_missing, signatures: []}
```

Every entry has a project-relative `path`, one-based `line`, `column`,
`end_line`, and `end_column`, and a `source_path` for the file that defines its
source or owner when that differs from `path`. Lists are `references`,
`methods`, `mixins`, `receivers`, `exposures`, `gaps`, and `resolves`. Unknown
fields, Ruby objects, and YAML aliases are rejected. A method signature has
`required` and `optional` counts, `keywords` and `optional_keywords` lists, and
`rest`, `keyword_rest`, `block`, and `forward` flags.

Version 1 files, written by ArchSpec 1.1, are still read. They carry
`references`, `methods`, and `gaps`, and go stale as a whole when any analyzed
file or input changes, or when `RAILS_ENV` differs from their `environment`.

Every `*.yml` file in the facts directory is loaded, in file name order. A file
written without `archspec reflect`, for example by a script in CI, works the
same way:

```ruby
facts = ArchSpec::Facts::Builder.new(graph, producer: "script")
facts.reference(source: "Invoice", target: "Customer", location: ["app/models/invoice.rb", 3])
ArchSpec::Facts.write("archspec_facts/script.yml", facts.to_document(sources: ["app/models/**/*.rb"]))
```

Build the graph with `ArchSpec::Analyzer.analyze(definition, root:, include_facts: false)`
so it does not import older facts.

## Static framework modeling

ActiveSupport concerns are handled without a producer. ArchSpec reads
`included`, `prepended`, and `class_methods` blocks and installs their methods
and mixins on each consumer through the same builder, in memory. Only
conditional callbacks need the runtime, which the Rails producer covers. See
[Concerns]({% link _rules/concerns.md %}).
