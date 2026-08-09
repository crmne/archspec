# frozen_string_literal: true

# Mastodon keeps general-purpose federation, routing, and database utilities in
# app/helpers and intentionally consumes them from models and services.
architecture :rails, share_helpers: true
