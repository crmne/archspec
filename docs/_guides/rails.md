---
title: Rails Applications
nav_order: 2
description: Configure ArchSpec for a conventional Rails application and enforce practical boundaries between controllers, models, services, and helpers.
---

# Rails Applications

After reading this guide, you will know:

- What the Rails architecture checks.
- How ArchSpec uses Rails conventions.
- How to add stricter architecture checks.

## What ArchSpec Uses

ArchSpec reads Ruby source with Prism. It does not boot Rails.

In Rails apps, the useful evidence is the file layout:

```text
app/controllers/users_controller.rb -> UsersController
app/models/user.rb                  -> User
app/services/billing/charge.rb       -> Billing::Charge
```

That convention gives ArchSpec enough information to check many boundaries cheaply.

## The Rails Architecture

```ruby
architecture :rails
```

The architecture defines controllers, models, helpers, mailers, jobs, and services. It also checks common boundaries:

- Models should not depend on controllers or helpers.
- Services should not depend on controllers or helpers.
- Models and services should not call controller-only APIs such as `render`, `redirect_to`, `params`, `session`, `cookies`, or `flash`.

## Add More Structure

Use another architecture when the app already has the matching folders:

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

Architectures are ordinary rules written for conventional Rails paths. Add local rules beside them when the app has its own vocabulary.

## Check Names

ArchSpec does not check Zeitwerk constant names. Zeitwerk does that itself. Add `Zeitwerk::Loader.eager_load_all` (or your loader's `eager_load`) to your test suite or CI:

```ruby
Zeitwerk::Loader.eager_load_all
```

It raises on any file that does not define the constant its path implies, using your real inflector and ignores.

## Engines and Packs

ArchSpec scans conventional engine and pack app paths by default:

```text
engines/*/app/**/*.rb
packs/*/app/**/*.rb
```

Define components for them when they are part of your architecture:

```ruby
component :billing, in: "engines/billing/app/**/*.rb"
component :catalog, in: "engines/catalog/app/**/*.rb"

billing.cannot_use :catalog
```
