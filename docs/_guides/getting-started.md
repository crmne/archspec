---
title: Getting Started
nav_order: 1
description: Install ArchSpec, generate an Archspec.rb file, run your first architecture check, and learn how to interpret a reported violation.
---

# Getting Started

After reading this guide, you will know:

- How to install ArchSpec.
- How to create an architecture file.
- How to run checks in a Rails app.
- How to read the first failure.

## Installation

ArchSpec requires Ruby 3.2 or newer.

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
architecture :rails
```
{: data-title="Archspec.rb"}

Add a fuller architecture when the app has a clear shape:

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

## Run It

```sh
bundle exec archspec check
```

ArchSpec exits with `0` when the rules pass and non-zero when they fail.

## Read a Failure

A failure shows the message and rule, the offending code, and the evidence
ArchSpec found:

```text
[error] models must not depend on controllers [dependencies.forbid]

app/models/user.rb:2:3

    1 │ class User < ApplicationRecord
  → 2 │   UsersController
      │   ^~~~~~~~~~~~~~~
    3 │ end

  note: User references UsersController
```

Run `explain` on the file to see how ArchSpec assigned it:

```sh
bundle exec archspec explain app/models/user.rb
```

```text
app/models/user.rb

  defined constants: User
  components:
    models: matched file pattern app/models/**/*.rb
  outgoing facts:
    1:14 │ inherits from ApplicationRecord
     2:3 │ references UsersController
```

## Commit the Spec

Treat `Archspec.rb` like a test file. A rule should describe a boundary the team is willing to enforce.
