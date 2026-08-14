---
layout: home
title: Architecture linter for Ruby and Rails
description: Static architecture linter for Ruby and Rails and a Packwerk alternative. Declare components and boundaries in one file, then check every change in CI.
permalink: /
hero:
  name: ArchSpec
  text: Executable architecture specifications for Ruby and Rails
  tagline: Guarantee your agents and your team follow your conventions. ArchSpec turns them into static analysis checks that run in CI on every change. No AI involved, just Prism.
  code_panel:
    - title: Boundaries
      link: /rules/dependencies/
      code: |
        ```ruby
        controllers.can_only_use :models, :services
        models.cannot_use :controllers
        services.cannot_call :render, :redirect_to
        ```
    - title: Failures explained
      link: /cli/
      code: |
        ```text
        [error] services must not call #render [methods.forbid]

        app/services/create_user.rb:7:5

          → 7 │     render :new
              │     ^~~~~~~~~~~

          note: CreateUser calls render
        ```
    - title: Rails
      link: /architectures/rails/
      code: |
        ```ruby
        architecture :rails

        jobs.cannot_reference_constants "Current"
        ```
    - title: Protocols
      link: /rules/protocols/
      code: |
        ```ruby
        component :commands, in: "app/commands/**/*.rb"

        commands.must_implement :call
        ```
    - title: Queries
      link: /rules/methods/
      code: |
        ```ruby
        component :queries, in: "app/queries/**/*.rb"

        queries.cannot_call :save!, :update!, :destroy!
        ```
    - title: No service objects
      link: /architectures/vanilla-rails/
      code: |
        ```ruby
        component :services, in: "app/services/**/*.rb"

        services.must_be_empty because: "rich models"
        ```
    - title: Modular monolith
      link: /architectures/modular-monolith/
      code: |
        ```ruby
        component :billing, in: "packs/billing/**/*.rb"
        component :catalog, in: "packs/catalog/**/*.rb"

        billing.can_only_use :catalog
        ```
  actions:
    - theme: brand
      text: Get started
      link: /getting-started/
    - theme: alt
      text: Check AI-written code
      link: /checking-ai-written-code/
    - theme: alt
      text: Configuration
      link: /configuration/

features:
  - icon: "⚡"
    title: Check on every commit
    details: "[`archspec check`](/getting-started/) reads your code with Prism, with no app boot and no database. Fast enough for CI, a git hook, and [every change an agent makes](/checking-ai-written-code/)."
  - icon: "🧱"
    title: Boundaries and dependencies
    details: "Allowed and forbidden [references](/rules/dependencies/) between layers and packs, [dependency direction and cycles](/rules/cycles/), [controller APIs kept out of models](/rules/methods/), [method protocols](/rules/protocols/), and [one-shot command objects](/rules/objects/)."
  - icon: "📐"
    title: Architectures included
    details: "Start from one that is already written: [Rails](/architectures/rails/), [vanilla Rails](/architectures/vanilla-rails/), [layered](/architectures/layered/), [hexagonal](/architectures/hexagonal/), [clean](/architectures/clean/), [modular monolith](/architectures/modular-monolith/), [CQRS](/architectures/cqrs/), [event-driven](/architectures/event-driven/). Or compose your own [rules](/rules/) in plain Ruby."
---
