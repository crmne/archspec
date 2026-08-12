---
title: Checking AI-Written Code
nav_order: 3
description: Use ArchSpec as a guardrail for generated code.
---

# Checking AI-Written Code

After reading this guide, you will know:

- Why architecture checks matter for generated code.
- How to use ArchSpec after an AI-assisted change.
- When to update the spec, todo file, or code.

## The Rule

Generated code should pass the same architecture checks as hand-written code.

ArchSpec helps because the rules are explicit and repeatable. A tool can write code quickly, but it does not know your team's boundaries unless those boundaries are executable.

## Review Flow

After an AI-assisted change, run:

```sh
bundle exec archspec check
```

If it fails, do not start by changing the spec. Read the evidence:

```text
[error] services must not call #redirect_to [methods.forbid]

app/services/create_user.rb:7:5

    6 │   def perform
  → 7 │     redirect_to root_path
      │     ^~~~~~~~~~~~~~~~~~~~~
    8 │   end

  note: CreateUser calls redirect_to
```

Then ask:

- Is the generated code in the right component?
- Did it call a framework API from the wrong place?
- Did it introduce a dependency direction the app does not allow?
- Is the rule still true?

Most failures should be fixed in the generated code.

## Use Explain

```sh
bundle exec archspec explain app/services/create_user.rb
```

```text
app/services/create_user.rb

  defined constants: CreateUser
  components:
    services: matched file pattern app/services/**/*.rb
  outgoing facts:
    3:5 │ calls create!
    7:5 │ calls redirect_to
```

`explain` shows the defined constants, component assignment, suppressions, and outgoing facts. Use it when a failure looks surprising.

## Do Not Hide New Failures

The todo file is for adopting ArchSpec in an existing app:

```ruby
todo "archspec_todo.yml"
```

```sh
bundle exec archspec check --update-todo
```

Do not update the todo file to accept new generated code. Fix the code, or change the rule intentionally.

## Local Suppressions

Use a local suppression only when the exception is deliberate and narrow:

```ruby
class User
  # archspec:disable-next-line dependencies.forbid -- legacy admin export
  Admin::UsersController
end
```

Prefer `disable-next-line` over block suppressions. The comment should say why the exception exists.
