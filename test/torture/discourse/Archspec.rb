# frozen_string_literal: true

# Discourse services declare their contract with a `params do ... end` DSL
# from Service::Base, so params stays available to services there.
architecture :rails, controller_api: %i[render redirect_to session cookies flash]
