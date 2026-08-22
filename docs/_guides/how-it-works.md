---
title: How It Works
nav_order: 5
description: Learn how ArchSpec collects Ruby files, parses source with Prism, builds its model, evaluates rules, and reports architecture diagnostics.
---

# How It Works

After reading this guide, you will know:

- The five stages between your source code and a diagnostic.
- What facts ArchSpec extracts and what it refuses to guess.
- Why checks are fast and safe to run anywhere.

## The Pipeline

ArchSpec never loads or executes your application. It reads source code with
[Prism](https://github.com/ruby/prism), Ruby's own parser, and everything
downstream is plain data:

```text
glob files -> parse -> extract facts -> assign components -> evaluate rules
```

1. **Collect.** The patterns from `source` (defaulting to `app/**/*.rb`,
   `lib/**/*.rb`, and pack/engine paths) are globbed from the project
   directory, minus `ignore` patterns. (`Analyzer.ruby_files`)
2. **Parse.** Each file goes through `Prism.parse_file`. Syntax errors
   become `parser.syntax` diagnostics instead of crashes, and
   `archspec:disable` comments are collected as suppressions.
3. **Extract facts.** A visitor walks the syntax tree and records edges in
   a graph: who defines what, who touches what. (`Analyzer::SourceVisitor`)
4. **Assign components.** Each `component` declaration claims files by glob
   and constants by namespace. A file can belong to several components; the
   `explain` command shows why. (`Graph.assign_components`)
5. **Evaluate.** Every rule reads the graph and emits diagnostics, which are
   then filtered through suppressions and the todo file, sorted, and printed.
   (`Evaluator.evaluate`)

## The Facts

Everything a rule can check is one of these edge types:

| Fact                       | Recorded when                                  |
| -------------------------- | ---------------------------------------------- |
| `references_constant`      | `UsersController` appears in an expression     |
| `inherits_from`            | `class User < ApplicationRecord`               |
| `includes` / `prepends` / `extends` | `include Billable` and friends        |
| `calls_named_method`       | any method call, by name                       |
| `instantiates_and_invokes` | `UserBuilder.new(params).build`                |
| `requires` / `requires_relative` | `require "csv"` with a literal string    |
| `dynamic_feature`          | `send`, `const_get`, `define_method`, `method_missing`, ... |

Alongside edges, the graph keeps each constant's methods and mixins (for
protocol rules).

A reference resolves the way Ruby resolves it, minus the guessing. The
lexical scopes around the reference are tried first, innermost out, then the
bare name. When none of those is defined, the walk follows the ancestors of
the class the reference sits in, in method resolution order: prepended
modules, included modules, then the superclass, and so on up. `Settings`
written inside `class User < Base` resolves to `Base::Settings` when `Base`
defines it, and `User::Settings` written elsewhere resolves the same way
through `User`. The walk refuses rather than guesses: it stops at the first
ancestor the graph does not hold (a gem's base class, a dynamic superclass),
and two ancestors at the same depth defining the name as different constants
is a miss, not a pick. Both refusals are counted in the "could not see" line,
and `explain` names the ancestor a reference resolved through.

A definition is a `class` or `module` keyword, or a constant assignment.
`MAX_RETRIES = 3` defines a plain constant; assigning `Class.new`,
`Struct.new`, or `Data.define` defines a class whose block is its body, and
`Module.new` defines a module. All of them belong to components and resolve
as reference targets like any other constant.

Run `archspec explain app/models/user.rb` to see the facts for one file.
It prints the defined constants, component assignments with reasons, and
every outgoing edge:

```text
app/models/user.rb

  defined constants: User
  components:
    models: matched file pattern app/models/**/*.rb
  outgoing facts:
    2:22 │ references UsersController
```

## A Violation, Traced

Given `models.cannot_use :controllers` and this file:

```ruby
class User
  def profile_path = UsersController
end
```
{: data-title="app/models/user.rb"}

Parsing records a `references_constant` edge from `app/models/user.rb` to
`UsersController`. Component assignment puts the file in `models` and puts
`UsersController` (defined in `app/controllers`) in `controllers`. The
`dependencies.forbid` rule walks dependency edges from `models`, resolves
`UsersController` the way Ruby would, innermost namespace outward, finds
it lands in a forbidden component, and emits:

```text
[error] models must not depend on controllers [dependencies.forbid]

app/models/user.rb:2:22

    1 │ class User
  → 2 │   def profile_path = UsersController
      │                      ^~~~~~~~~~~~~~~
    3 │ end

  note: User references UsersController
```

## Dynamic Code

Static analysis cannot see through `send`, `const_get`, or `method_missing`.
ArchSpec records these as `dynamic_feature` facts with confidence
`unknown_due_to_dynamic_feature` instead of ignoring them, and every
diagnostic carries the evidence it was derived from, so you can verify a
report against the source line it points to. A diagnostic inside a
constant that uses one of them prints at medium confidence with the
feature and its line in the note. Every run ends with a census of what
it could not see, by cause, so silence is never mistaken for agreement.

Because ArchSpec only parses code and never loads it, checks need no Rails
boot, no database, and have no side effects. They are safe to run in CI, in
a git hook, or after an AI-assisted change.
