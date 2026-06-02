# ArchSpec

Architecture checks for Ruby and Rails.

It checks explicit structural rules: components, layers, constant references,
inheritance, mixins, named method calls, callable object protocols, cycles, and
Rails boundary conventions. It does not try to infer the "true" design pattern
of arbitrary Ruby code.

```ruby
# Archspec.rb
ArchSpec.define "Application architecture" do
  root "."
  preset :rails_way

  component :controllers, in: "app/controllers/**/*.rb"
  component :models,      in: "app/models/**/*.rb"
  component :services,    in: "app/services/**/*.rb"

  controllers.can_use :models, :services
  models.cannot_use :controllers
  services.must_implement :call
  services.cannot_call :render, :redirect_to, :params, :session
end
```

Run it with:

```sh
archspec check
```

Useful commands:

```sh
archspec init
archspec check --format json
archspec check --update-baseline
archspec explain app/models/user.rb
```

This repository dogfoods ArchSpec with:

```sh
rake architecture
```

Local suppressions are intentionally narrow:

```ruby
# archspec:disable-next-line dependencies.forbid -- legacy admin export
Admin::UsersController
```

Read the short guides in `docs/` for setup, Rails usage, and reviewing
AI-written code with the same architecture rules as hand-written code.
