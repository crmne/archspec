# frozen_string_literal: true

# Discourse services declare their contract with a `params do ... end` DSL
# from Service::Base, so params stays available to services there. It also
# shares rendering helpers with service objects such as notification renderers.
architecture :rails,
             controller_api: %i[render redirect_to session cookies flash],
             share_helpers: true
