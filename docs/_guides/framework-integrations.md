---
title: Framework integrations
nav_order: 6
description: Build ArchSpec framework integrations with shared semantic facts, explicit runtime reflection, and a versioned format for portable static checks.
---

# Framework integrations

ArchSpec rules read one graph of constants, methods, and relationships.
Framework integrations contribute evidence through `ArchSpec::Facts::Builder`.
A static semantic pass applies its facts in memory; a runtime producer saves
those facts for later static checks. Both routes use the same validator and
application code.

| Integration | How it establishes behavior | How it supplies facts |
| --- | --- | --- |
| ActiveSupport concerns | Interprets explicit source declarations | `Builder#apply` during analysis |
| Active Record associations | Asks the loaded framework to resolve associations | `Builder#to_document` during `archspec reflect` |
| Another framework or macro library | Uses runtime reflection or authoritative metadata | Writes its own facts file with the same builder |

```text
source indexing -> framework syntax normalization -> shared facts -> graph -> rules
                                                         ^
explicit runtime producer -> versioned snapshot -> validation
```

`check` and `explain` consume snapshots as data. They never invoke a producer
automatically when they encounter a gap. `archspec reflect` currently runs the
built-in Rails producer; other producers use their own explicit command.
Static semantic passes remain part of the analyzer, with no public registration
API.

## Why concerns still have a static pass

For a module that explicitly extends `ActiveSupport::Concern`, ArchSpec models
supported declarations inside `included`, `prepended`, and `class_methods`
blocks. It follows concern dependencies and determines which consumers receive
methods and mixins. This needs no application boot or snapshot.

The framework-specific pass first corrects the initial interpretation of the
source. For example, a method defined inside `included` belongs to a consumer.
After removing provisional ownership and deferred mixins, the pass uses the
shared builder to establish methods, ordered mixins, method exposures, callback
receiver bindings, and gaps.

The application layer preserves method metadata and installation precedence.
Constant references retain their lexical scope, while supported receiverless
calls resolve against the consumer's API. Framework interpretation belongs in
the semantic pass; applying these established relationships is shared with
external facts producers.

Conditional callback methods and mixins remain gaps. A custom producer can
record effects it establishes for the captured runtime using the same method
and mixin facts. Capturing one runtime does not prove what every branch or
environment would do. The built-in Rails reflector currently captures
associations, not validators or arbitrary callback effects.

See [Concerns]({% link _rules/concerns.md %}) for supported static behavior.

## Combining source analysis and reflection

An association such as `belongs_to :customer` does not spell out its target
constant. The Rails producer asks the loaded framework to resolve it using the
application's configuration and records the dependency. It also captures
confirmed association readers and writers.

Both paths can contribute to the same declaration:

```ruby
module Owned
  extend ActiveSupport::Concern

  included do
    belongs_to :customer
  end
end

class Invoice < ApplicationRecord
  include Owned
end
```

Static modeling establishes that `Invoice` consumes `Owned`. The Rails producer
uses the model's real association reflection to establish its target, then
matches it to the declaration in `Owned`. The reference belongs to `Invoice`,
with its diagnostic location in the concern. Dependency rules can then check
the model's dependency on the resolved customer class.

See [Association reflection]({% link _guides/association-reflection.md %}) for the
Rails capture command and snapshot lifecycle.

## Write a custom facts producer

A producer can live in an application script or a separate gem. It explicitly
boots its framework when needed, establishes relationships using reflection or
authoritative metadata, and matches that evidence to analyzed source. It need
not depend on Rails.

Use the same `definition` and project `root` as your checks. Build a graph with
`include_facts: false` to avoid importing previous snapshots. Given evidence
that a macro on line 3 of `app/models/invoice.rb` creates a dependency on
`Customer` and methods `customer` and `customer=`, a producer can write:

```ruby
require "archspec"

graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
raise ArchSpec::Error, "cannot capture facts for invalid source" if
  graph.files.values.any? { |file| file.parse_errors.any? }

directory = definition.facts_path
raise ArchSpec::Error, "configure a facts directory first" unless directory

invoice_path = File.join(graph.root, "app/models/invoice.rb")
invoice = graph.constants_named("Invoice").find { |node| node.path == invoice_path }
location = ArchSpec::SourceLocation.point(invoice_path, 3, 1)

facts = ArchSpec::Facts::Builder.new(graph, producer: "my_library")
facts.reference(source: invoice, target: "Customer", location: location)
facts.methods(owner: invoice, names: ["customer", "customer="], location: location)

document = facts.to_document(facts_path: directory)
ArchSpec::Facts.write(File.join(File.expand_path(directory, root), "my_library.yml"), document)
```

The example values represent evidence supplied by the producer; the builder
validates their format and source locations, but does not independently prove
the runtime claims. When evidence comes from a concern, supply the model's
constant node as the owner and the concern declaration as the location. The
builder records the two files separately.

`to_document` validates entries before returning a versioned snapshot.
`Facts.write` writes it atomically. Finish collecting evidence before writing,
so a failed capture preserves the previous file. Keep output deterministic and
refresh only your producer's file. Use the configured facts directory when
creating the document so snapshots under `config/` do not fingerprint themselves.

For a static integration, `facts.apply` validates and applies the collected
entries directly to the current graph without writing a snapshot. Build the
complete batch first: call receiver resolution runs after methods and mixins
have been installed. Facts construction itself does not mutate the graph.

### Builder operations

Owners and sources are `ArchSpec::ConstantNode` objects from the graph. Locations
are `ArchSpec::SourceLocation` objects. Constant targets and receivers are fully
qualified constant names.

| Operation | Arguments and effect |
| --- | --- |
| `reference` | `source:`, `target:`, `location:` add a resolved constant dependency |
| `methods` | `owner:`, `names:`, `location:` establish methods; optional `scope:`, `visibility:`, `signatures:`, `alias_target:`, `mode:`, `installation:` retain richer metadata |
| `method_definition` | `owner:`, `definition:` copy a graph method definition with its metadata; optional `installation:` supplies callback precedence |
| `mixin` | `owner:`, `target:`, `kind:`, `location:` install a mixin and its dependency edge |
| `bind_receiver` | `edge:`, `receiver:`, `scope:` bind an existing receiverless call while retaining its lexical owner and location |
| `expose_methods` | `source:`, `owner:`, `scope:` classify a module's instance definitions as another owner's API for naming and declaration checks |
| `gap` | `source:`, `message:`, `location:` record behavior the integration cannot establish |

Mixins accept `include`, `prepend`, `extend`, and `singleton_prepend`. Emit them
in installation order; lookup gives later installations precedence within each
kind. Method exposure is a classification operation. It does not install an API
on a consumer: emit the appropriate mixin or method facts for that.

Method scope defaults to `instance`; `class` is also supported. Visibility
defaults to `public` and also accepts `protected` and `private`. Signatures may
be graph `MethodSignature` objects or hashes with the fields described below.
Omitting signatures establishes method presence without claiming arity or
keyword compatibility.

`methods` defaults to `mode: :if_missing`, which retains an existing definition
on the same owner with the same name and scope. `method_definition` defaults to
`:append`, preserving distinct source definitions. With an `installation:`
location it uses `:define`, replacing prior definitions while retaining a local
definition later than that installation in the owner's file. Emit callback
installations in execution order; the declaration's location remains the
method's evidence location.

## Versioned document contract

New producers emit version 2. Existing version 1 files remain readable with
their original references, method names, and gaps; version 1 rejects the new
fields. Documents use string keys. Unknown fields, Ruby objects, and YAML
aliases are rejected.

| Document field | Meaning |
| --- | --- |
| `version` | Required integer: `1` or `2` |
| `producer` | Required nonempty producer name; identifies the document, not a registered Ruby class |
| `snapshot` | Required exact input hash map returned by `Facts.snapshot` for the current analysis |
| `environment` | Optional Rails environment string; if `RAILS_ENV` is set during loading, it must match |
| `references` | Entries with `source`, `target`, and a location |
| `methods` | Entries with `owner`, `scope`, nonempty `names`, and a location |
| `mixins` | Version 2 entries with `owner`, `target`, `kind`, and a location |
| `receivers` | Version 2 entries with `source`, `name`, `receiver`, `scope`, and a complete call location |
| `exposures` | Version 2 entries with module `source`, analyzed `owner`, `scope`, and a location |
| `gaps` | Entries with `source`, nonempty `message`, and a location |

All fact lists are optional. Each entry requires a project-relative `path` and
a positive `line` identifying an analyzed file. Optional `column`, `end_line`,
and `end_column` use one-based byte coordinates. Defaults are column 1, the
starting line, and the starting column respectively. The complete range must
lie within the source file.

`source` and `owner` identify constants defined in `source_path`, which defaults
to `path`. For exposures, `source_path` identifies the source module's file;
`owner` identifies an analyzed constant. Targets can name external declarations,
but component-based dependency checks require a target to be analyzed and
assigned to a component.

Version 2 methods add optional `visibility`, `signatures`, `alias_target`,
`mode`, and `installation` fields. Defaults are `public`, an empty signature
list, no alias, and `if_missing`. `mode` accepts `if_missing`, `append`, or
`define`; `define` requires an `installation` location with `path`, `line`, and
optional column/end coordinates. Other modes cannot specify an installation.
An alias target is a nonempty method name.

Each signature accepts these fields:

| Field | Value and default |
| --- | --- |
| `required`, `optional` | Nonnegative positional argument counts, default `0` |
| `keywords`, `optional_keywords` | Lists of nonempty keyword names, default empty; required and optional names must not overlap |
| `rest`, `keyword_rest`, `block`, `forward` | Booleans, default `false` |

### Application and conflict behavior

Every top-level `*.yml` file in the configured directory is loaded in filename
order; the directory must contain at least one file. All documents are decoded
and validated before any imported facts are applied. An invalid or stale file
fails loading without partially applying earlier files.

References are deduplicated at the same source location. Mixins preserve their
installation order and do not reinstall the same target within the same kind.
Methods follow their explicit mode. Conflicting method exposures for the same
module are rejected before application, including conflicts with static
exposures.

Receiver facts must identify an existing receiverless call by source owner,
name, and its exact full source range. They cannot invent calls. All bindings
for a call across the imported documents are combined, then replace that call's
previous receiver interpretation. Emit the complete set of consumers for each
bound call. Resolution runs after every document's methods and mixins are
applied, including method aliases, while preserving lexical source ownership.

Gaps appear in analysis-gap output without creating dependencies. Facts do not
automatically remove an earlier static gap or choose which contradictory
runtime claim is true. Producers must supply consistent evidence for the
captured configuration. In particular, these facts cannot create arbitrary
constants, remove provisional methods, or rewrite lexical constant references;
framework source normalization still owns those operations.

### Freshness and integration tests

Snapshots cover analyzed files and the configuration and dependency inputs
listed in [Keep snapshots current]({% link _guides/association-reflection.md %}#keep-snapshots-current).
They do not fingerprint arbitrary framework inputs or environment variables.
The environment field retains Rails-specific validation; it is not a general
environment fingerprint. Arrange regeneration when inputs outside the snapshot
change. A snapshot describes the captured runtime configuration.

Test an integration by importing its document into a fresh analysis and checking
actual rule diagnostics. Compare the result with applying its builder in memory
and, where possible, the real framework behavior. Include ambiguous evidence,
method precedence, calls with multiple consumers, and application code that
would fail if a static check tried to execute it.

For custom validators, serializers, or another macro library, emit the confirmed
relationships and APIs using these operations. If metadata cannot establish a
unique declaration or target, record a gap at an established owner/location.
Avoid choosing a plausible target from naming conventions. A polymorphic
association, for example, can establish reader/writer methods while leaving its
target dependency unknown.

## Remaining work

The shared facts layer is implemented. The broader framework reflection
workflow is unfinished. This checklist records the remaining work so the
refactor can be resumed without treating the builder as a complete integration
system.

- [ ] **Producer registration and execution.** Replace the direct
  `CLI.reflect` dependency on `RailsReflector` with an explicit producer
  interface. Specify selection, configuration, boot isolation, output ownership,
  and failure behavior. Demonstrate a third-party producer running through
  `archspec reflect` without changing the CLI or architecture rules. Static
  semantic passes also still lack a public registration interface; decide
  separately whether those need to be extensible.
- [ ] **Producer-specific freshness.** Allow producers to declare additional
  input files and runtime context that affect their claims. Define how changes,
  additions, and removals invalidate snapshots, including framework versions
  and relevant environment settings. Preserve compatibility with existing
  snapshots and avoid including secrets in captured context. The current
  fixed file list and `RAILS_ENV` check are insufficient for arbitrary frameworks.
- [ ] **Dynamic concern reflection.** Implement a producer that captures
  observed callback methods and mixins, attributes them to their consumers, and
  retains declaration evidence. Compare conditional callbacks, transitive
  concerns, prepend order, and multiple consumers against real ActiveSupport
  behavior. Keep claims limited to the captured runtime; uncertain source
  attribution must remain a gap.
- [ ] **Rails validator reflection.** Capture confirmed custom-validator
  dependencies with declaration locations. Cover namespaced validators,
  inherited registrations, and ambiguous or dynamic declarations without
  inferring targets solely from naming conventions.
- [ ] **Evidence provenance and reconciliation.** Retain producer identity and
  runtime context on individual graph facts. Define which specific static gap
  an observation can resolve and how conflicting claims are reported. Existing
  method modes and exposure conflict checks do not provide general
  reconciliation; importing facts currently leaves static gaps in place.
- [ ] **Runtime-created declarations.** Decide how to represent named classes
  and modules absent from the source index, with ownership, component assignment,
  and usable evidence. Define the behavior for anonymous or untraceable owners
  before extending the schema. The current contract requires analyzed owners.
- [ ] **A real non-Rails integration.** Exercise the producer interface with
  another framework or macro library, including booting, metadata discovery,
  source matching, snapshot invalidation, and downstream rule diagnostics. The
  existing custom-fact tests cover the contract, but not that complete workflow.

Start with producer registration and freshness, then implement a dynamic concern
producer and a non-Rails producer through that interface. Use those integrations
to establish the provenance and gap-resolution semantics before expanding the
schema for runtime-created declarations. Validator capture can then use the
same producer interface.

When resuming, preserve the static `check`/`explain` boundary, version 1 loading,
and validation before graph mutation. Run `ARCHSPEC_TORTURE=1 bundle exec rake`
to check the fact contract, real ActiveSupport behavior, architecture rules,
and the pinned Fizzy, Discourse, and Mastodon regression snapshots. Reflection
will still describe an observed configuration, not every possible execution.
