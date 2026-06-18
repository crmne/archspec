# ArchSpec

Architecture checks for Ruby and Rails.

Turn your application's architecture into executable checks.

ArchSpec reads Ruby source with Prism, maps conventional Rails files to
constants, and checks the structural rules you write down: components, layers,
constant references, inheritance, mixins, named method calls, method protocols,
cycles, and Rails boundaries.

It does not try to infer the "true" design pattern of arbitrary Ruby code. You
describe the architecture your team wants. ArchSpec checks whether the code still
matches it.

## Why ArchSpec?

Architecture usually lives in pull request comments, onboarding docs, and senior
engineers' heads. That does not scale well, especially when code is moving fast.

ArchSpec gives you a small Ruby DSL for the rules that code review otherwise has
to remember:

- models do not reach into controllers
- domain code does not depend on adapters
- packs only depend on approved packs
- query objects do not call obvious write methods
- generated code follows the same boundaries as hand-written code

## Show me the code

Start with conventional Rails boundaries:

```ruby
# Archspec.rb
ArchSpec.define "Application architecture" do
  preset :rails_way
end
```

Go vanilla, 37signals style — rich models, no service objects:

```ruby
ArchSpec.define "Application architecture" do
  preset :vanilla_rails
end
```

Add layers when the app has a clear direction of dependencies:

```ruby
ArchSpec.define "Application architecture" do
  architecture :layered, layers: {
    interface: "app/controllers/**/*.rb",
    application: "app/services/**/*.rb",
    domain: "app/models/**/*.rb"
  }
end
```

Keep a hexagonal core away from adapters:

```ruby
ArchSpec.define "Application architecture" do
  architecture :hexagonal,
    application: %w[app/services/**/*.rb app/use_cases/**/*.rb],
    domain: "app/domain/**/*.rb",
    ports: "app/ports/**/*.rb",
    adapters: %w[app/adapters/**/*.rb app/integrations/**/*.rb]
end
```

Check a modular monolith:

```ruby
ArchSpec.define "Application architecture" do
  architecture :modular_monolith,
    components: {
      billing: "packs/billing/**/*.rb",
      catalog: "packs/catalog/**/*.rb",
      shared: "packs/shared/**/*.rb"
    },
    allow: {
      billing: %i[shared],
      catalog: %i[shared]
    }
end
```

Write local rules in plain Ruby:

```ruby
ArchSpec.define "Application architecture" do
  component :controllers, in: "app/controllers/**/*.rb"
  component :models, in: "app/models/**/*.rb"
  component :services, in: "app/services/**/*.rb"

  controllers.can_use :models, :services
  models.cannot_use :controllers
  services.cannot_call :render, :redirect_to, :params, :session
  services.cannot_instantiate_and_invoke
end
```

Check command/query separation:

```ruby
ArchSpec.define "Application architecture" do
  architecture :cqrs,
    commands: "app/commands/**/*.rb",
    queries: "app/queries/**/*.rb",
    read_models: "app/read_models/**/*.rb"
end
```

## What It Checks

- **Dependencies:** allowed and forbidden references between components
- **Layers:** dependency direction and cycles
- **Rails MVC:** controller APIs kept out of models and services
- **Architectures:** Rails MVC, layered, hexagonal, clean, modular monolith, CQRS, and event-driven bundles
- **Protocols:** required methods such as `resolve`, `perform`, or project-specific interfaces
- **Objects:** rules against one-shot `Something.new(...).whatever` command objects
- **Zeitwerk names:** conventional file names defining the expected constants
- **Empty components:** directories that must stay empty, like `app/services` in vanilla Rails
- **Suppressions:** narrow local exceptions with a reason

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
bundle exec archspec check --update-baseline
bundle exec archspec explain app/models/user.rb
```

`explain` shows why a file or constant belongs to a component and which outgoing
facts ArchSpec found.

## Checking AI-Written Code

Generated code should pass the same architecture checks as hand-written code.

After an AI-assisted change:

```sh
bundle exec archspec check
```

If it fails, read the evidence before changing the spec:

```text
[dependencies.forbid] app/models/user.rb:2:3
  models must not depend on controllers
  evidence: User references_constant UsersController
  confidence: high
```

Most failures should be fixed in the generated code. Update the spec only when
the architecture decision itself has changed.

## Baselines and Suppressions

Use a baseline when adopting ArchSpec in an existing app:

```ruby
baseline ".archspec_todo.yml"
```

```sh
bundle exec archspec check --update-baseline
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

## License

Released under the MIT License.
