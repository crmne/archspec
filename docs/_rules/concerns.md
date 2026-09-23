---
title: Concerns
nav_order: 9
description: Use ArchSpec concern rules to keep reusable modules independent from the concrete classes that include them in Ruby and Rails applications.
seo:
  title: Concern independence rules
---

# Concerns

A concern is a module mixed into other classes. It should not know which classes use it.

```ruby
component :model_concerns, in: "app/models/concerns/**/*.rb"
model_concerns.cannot_reference_includers
```

Rule id: `concerns.independence`

ArchSpec finds every class that includes, prepends, or extends a concern, then flags the concern for referencing that class by constant.

```ruby
module Chargeable
  def charge
    Order.create!(...)  # Chargeable must not reference its includer Order
  end
end

class Order < ApplicationRecord
  include Chargeable
end
```

A concern that names its includer couples the two and defeats the point of extracting it. Passing behavior through the instance, such as `self` or a method the includer defines, does not trigger the rule.

Modules that explicitly `extend ActiveSupport::Concern` receive Rails concern
semantics. `class_methods` blocks and nested `ClassMethods` modules provide the
consumer's class API; naming checks classify those methods in `scope: :class`.
Their signatures and visibility participate in protocol checks on consumers.

An `include`, `prepend`, or `extend` directly inside `included` or `prepended`
runs on the consumer, and does not make the concern itself an includer.
ArchSpec applies the matching callback and follows dependencies between
concerns. Constant references keep their Ruby lexical scope. Ordinary modules
and direct module-body mixins retain ordinary Ruby behavior.

This analysis does not execute callbacks. Conditional mixins and method
definitions inside callbacks remain analysis gaps; it does not choose a runtime
branch or infer methods from arbitrary callback execution.

Concern modeling and external reflection contribute to the same analysis graph.
The [framework integration guide]({% link _guides/framework-integrations.md %})
explains why concerns use static modeling and what runtime facts can add.

The `:rails_strict` and `:vanilla_rails` architectures apply this to `app/**/concerns/**/*.rb`. Override the glob with `concerns:`, or pass `concerns: false` to skip it.
