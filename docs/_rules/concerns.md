---
title: Concerns
nav_order: 10
description: Keep concerns independent of the classes that include them.
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

The `:rails_strict` and `:vanilla_rails` architectures apply this to `app/**/concerns/**/*.rb`. Override the glob with `concerns:`, or pass `concerns: false` to skip it.
