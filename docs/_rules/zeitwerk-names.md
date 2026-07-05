---
title: Zeitwerk Names
nav_order: 8
description: Check conventional Rails file-to-constant names.
---

# Zeitwerk Names

Use this rule when the project follows Rails and Zeitwerk naming conventions.

```ruby
verify_zeitwerk_names!
```

Rule id: `zeitwerk.naming`

ArchSpec computes the expected constant from conventional paths:

```text
app/models/user.rb            -> User
app/services/billing/charge.rb -> Billing::Charge
```

It then checks whether the file defines that constant.

## Acronyms

Declare the acronyms your app inflects so names line up:

```ruby
inflect "api" => "API", "graphql" => "GraphQL"

verify_zeitwerk_names!
```

`app/models/api_client.rb` then expects `APIClient`, and `app/models/api.rb` expects `API`. Copy the rules from your `config/initializers/inflections.rb`.

## Scope

Rails does not autoload `lib` unless you opt in with `config.autoload_lib`. When `lib` files are required by hand, they do not follow Zeitwerk naming. Pass globs to check only the autoloaded tree:

```ruby
verify_zeitwerk_names! "app/**/*.rb"
```

With no arguments the rule checks every file ArchSpec can name.

Do not use this rule for projects that intentionally keep multiple classes in one file.
