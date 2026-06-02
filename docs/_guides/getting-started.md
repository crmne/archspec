---
title: Getting Started
nav_order: 1
description: Install ArchSpec and run the first architecture check.
---

# Getting Started

After reading this guide, you will know:

- How to install ArchSpec.
- How to create an architecture file.
- How to run checks in a Rails app.
- How to read the first failure.

## Installation

Add ArchSpec to your Gemfile:

```ruby
group :development, :test do
  gem "archspec"
end
```
{: data-title="Gemfile"}

Then install it:

```sh
bundle install
```

## Create the Spec

Run:

```sh
bundle exec archspec init
```

This creates `Archspec.rb`:

```ruby
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

## Run It

```sh
bundle exec archspec check
```

ArchSpec exits with `0` when the rules pass and non-zero when they fail.

## Read a Failure

A failure shows the rule, file, line, message, evidence, confidence, and stable id:

```text
[dependencies.forbid] app/models/user.rb:2:3
  models must not depend on controllers
  evidence: User references_constant UsersController
  confidence: high
```

Run `explain` on the file to see how ArchSpec assigned it:

```sh
bundle exec archspec explain app/models/user.rb
```

## Commit the Spec

Treat `Archspec.rb` like a test file. A rule should describe a boundary the team is willing to enforce.
