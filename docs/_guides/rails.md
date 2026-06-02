---
title: Rails Applications
nav_order: 2
description: Use ArchSpec with conventional Rails apps.
---

# Rails Applications

After reading this guide, you will know:

- What the Rails preset checks.
- How ArchSpec uses Rails conventions.
- How to add service and command object checks.

## What ArchSpec Uses

ArchSpec reads Ruby source with Prism. It does not boot Rails.

In Rails apps, the useful evidence is the file layout:

```text
app/controllers/users_controller.rb -> UsersController
app/models/user.rb                  -> User
app/services/billing/charge.rb       -> Billing::Charge
```

That convention gives ArchSpec enough information to check many boundaries cheaply.

## The Rails Preset

```ruby
ArchSpec.define "Application architecture" do
  root "."
  preset :rails_way
end
```

The preset defines controllers, models, helpers, mailers, jobs, and services. It also checks common boundaries:

- Models should not depend on controllers or helpers.
- Services should not depend on controllers or helpers.
- Models and services should not call controller-only APIs such as `render`, `redirect_to`, `params`, or `session`.

## Add Callable Objects

Many Rails teams use services or commands as callable objects:

```ruby
component :services, in: "app/services/**/*.rb"
services.must_implement :call
services.cannot_call :render, :redirect_to, :params, :session
```

This does not prove every service is well-designed. It catches drift from the convention.

## Check Names

Use this when the app follows Zeitwerk naming:

```ruby
verify_zeitwerk_names!
```

ArchSpec reports files whose expected constant does not appear in the file.

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
