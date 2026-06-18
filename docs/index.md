---
layout: home
title: Architecture linter for Ruby and Rails
description: ArchSpec is a static architecture linter for Ruby and Rails, a Packwerk alternative. Declare components, dependencies, and boundaries in one file and check them in CI. No app boot, no database.
permalink: /
hero:
  name: ArchSpec
  text: Turn your architecture into checks that run in CI
  tagline: ArchSpec is an architecture linter for Ruby and Rails. Declare your components, dependencies, and boundaries in one file, then check every change in CI, whether a person or a coding agent wrote it. It reads source with Prism and never boots the app.
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
  - title: Rails-aware static analysis
    details: Maps Rails and Zeitwerk files to constants, so it understands controllers, models, and service objects. Extracts references, inheritance, and method calls without a database or app boot.
  - title: Boundaries and dependencies
    details: Check allowed and forbidden references between layers and packs, dependency direction, cycles, MVC boundaries, and method protocols. Start from a preset for layered, hexagonal, clean, modular monolith, CQRS, event-driven, or vanilla Rails.
  - title: Same rules for AI-written code
    details: Generated code passes the same checks as hand-written code. `archspec explain` shows why a file belongs to a component and which facts triggered a rule.
---
