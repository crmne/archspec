---
title: Objects
nav_order: 5
description: Use ArchSpec object rules to prevent one-shot command-object patterns that instantiate a class and immediately invoke a selected method.
seo:
  title: Object usage rules
---

# Objects

Use this rule when the project avoids classes that only exist to be instantiated and immediately invoked.

```ruby
library.cannot_instantiate_and_invoke
```

Rule id: `objects.instantiate_and_invoke_forbid`

This fails on code shaped like:

```ruby
SuppressionParser.new(comments).parse
UserBuilder.new(params).build
```

The usual replacement is a module API:

```ruby
module SuppressionParser
  extend self

  def parse(comments)
    # ...
  end
end

SuppressionParser.parse(comments)
```

This rule is about one-shot object ceremony. It is not a general ban on objects.
