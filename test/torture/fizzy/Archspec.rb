# frozen_string_literal: true

# Fizzy is a 37signals app, so it exercises the vanilla_rails preset whose
# empty-directory rules were distilled from 37signals conventions. Its model
# POROs intentionally reuse view helpers for notification and timeline output.
architecture :vanilla_rails, share_helpers: true

# Keep the convention pack on the small every-push torture target so its
# project-wide method scan gets exercised without overwhelming larger apps.
preset :ruby_conventions
