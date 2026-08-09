# ArchSpec

Architecture linter for Ruby and Rails.

ArchSpec turns your application's architecture into executable checks. Declare
your components, dependencies, and boundaries in one file, then check every
change in CI, whether a person or a coding agent wrote it. It reads Ruby source
with Prism and never boots the app.

It maps conventional Rails files to constants and checks the structural rules
you write down: components, layers, constant references, inheritance, mixins,
named method calls, method protocols, cycles, and Rails boundaries.

It does not try to infer the "true" design pattern of arbitrary Ruby code. You
describe the architecture your team wants. ArchSpec checks whether the code still
matches it.

## Why ArchSpec?

Architecture usually lives in pull request comments, onboarding docs, and senior
engineers' heads. That does not scale well, especially when code is moving fast.
More of that code is now written by coding agents that do not know your
conventions.

ArchSpec gives you a small Ruby DSL for the rules that code review otherwise has
to remember, and checks them on every change:

- models do not reach into controllers
- domain code does not depend on adapters
- packs only depend on approved packs
- query objects do not call obvious write methods
- generated code follows the same boundaries as hand-written code

## Show me the code

Start with conventional Rails boundaries:

```ruby
architecture :rails
```

Go vanilla, 37signals style, with rich models and no service objects:

```ruby
architecture :vanilla_rails
```

Add layers when the app has a clear direction of dependencies:

```ruby
architecture :layered
```

Override the default directories when the app uses different names:

```ruby
architecture :layered, layers: {
  interface: "app/controllers/**/*.rb",
  application: "app/services/**/*.rb",
  domain: "app/models/**/*.rb"
}
```

Keep a hexagonal core away from adapters:

```ruby
architecture :hexagonal
```

Check a modular monolith, and make packs go through a public API:

```ruby
architecture :modular_monolith,
  components: {
    billing: "packs/billing/**/*.rb",
    catalog: "packs/catalog/**/*.rb",
    shared: "packs/shared/**/*.rb"
  },
  allow: {
    billing: %i[shared],
    catalog: %i[shared]
  },
  public: {
    billing: "packs/billing/app/public/**/*.rb"
  }
```

Write local rules in plain Ruby:

```ruby
component :controllers, in: "app/controllers/**/*.rb"
component :models, in: "app/models/**/*.rb"
component :services, in: "app/services/**/*.rb"

controllers.can_only_use :models, :services
models.cannot_use :controllers
services.cannot_call :render, :redirect_to, :params, :session
services.cannot_instantiate_and_invoke
```

Check command/query separation:

```ruby
architecture :cqrs,
  commands: "app/commands/**/*.rb",
  queries: "app/queries/**/*.rb",
  read_models: "app/read_models/**/*.rb"
```

## What It Checks

- **Dependencies:** allowed and forbidden references between components, in both directions
- **Privacy:** other components must go through a component's public API
- **Concerns:** a concern must not depend on the classes that include it
- **Layers:** dependency direction and cycles
- **Rails:** controller APIs kept out of models and services
- **Architectures:** Rails, vanilla Rails, layered, hexagonal, clean, modular monolith, CQRS, event-driven, and Ruby conventions bundles
- **Protocols:** required methods such as `resolve`, `perform`, or project-specific interfaces
- **Naming:** conventions on a component's public API, such as banning `get_`/`set_` or pairing `with_x` with `without_x`
- **Objects:** rules against one-shot `Something.new(...).whatever` command objects
- **Empty components:** directories that must stay empty, like `app/services` in vanilla Rails
- **Suppressions:** narrow local exceptions with a reason

## Checking Zeitwerk Names

ArchSpec does not check Zeitwerk constant names. Zeitwerk does that itself. Add `Zeitwerk::Loader.eager_load_all` (or your loader's `eager_load`) to your test suite or CI. It raises on any file that does not define the constant its path implies, using your real inflector and ignores.

## Installation

Add ArchSpec to your Gemfile:

```ruby
group :development, :test do
  gem "archspec"
end
```

Then install it:

```sh
bundle install
```

Create `Archspec.rb`:

```sh
bundle exec archspec init
```

Run the checks:

```sh
bundle exec archspec check
```

## Commands

```sh
bundle exec archspec init
bundle exec archspec check
bundle exec archspec check --format json
bundle exec archspec check --update-todo
bundle exec archspec explain app/models/user.rb
```

`explain` shows why a file or constant belongs to a component and which outgoing
facts ArchSpec found.

## Checking AI-Written Code

Generated code should pass the same architecture checks as hand-written code.

After an AI-assisted change, check the whole project, or just the files that changed:

```sh
bundle exec archspec check
bundle exec archspec check app/models/user.rb app/services
```

Passing paths still analyzes the project so dependencies resolve, but reports only violations in those paths. This keeps the loop tight after each edit.

If it fails, read the evidence before changing the spec:

```text
[dependencies.forbid] app/models/user.rb:2:3
  models must not depend on controllers
  evidence: User references_constant UsersController
  confidence: high
```

Most failures should be fixed in the generated code. Update the spec only when
the architecture decision itself has changed.

## Todo and Suppressions

Use a todo file when adopting ArchSpec in an existing app. It records the current
violations so they stop failing the build, leaving a list to burn down:

```ruby
todo "archspec_todo.yml"
```

```sh
bundle exec archspec check --update-todo
```

Use local suppressions for deliberate exceptions:

```ruby
# archspec:disable-next-line dependencies.forbid -- legacy admin export
Admin::UsersController
```

## Documentation

Read the guides at [archspecrb.dev](https://archspecrb.dev/).

## Dogfooding

This repository checks its own architecture:

```sh
bundle exec rake architecture
```

It also runs against pinned checkouts of large real-world Rails apps to catch crashes and false positives before they ship:

```sh
bundle exec rake torture
```

## License

Released under the MIT License.
