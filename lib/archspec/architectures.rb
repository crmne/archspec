# frozen_string_literal: true

module ArchSpec
  # Bundled architecture presets. Each applies a set of components and rules in
  # one call, invoked from the DSL through
  # ArchSpec::DSL::Context#architecture:
  #
  #   architecture :rails
  #   architecture :layered, layers: { ... }
  #
  # Every preset accepts overrides for its directories, so you can keep the
  # shape while pointing at your own paths. The presets are:
  #
  # - +:rails+ (aliases +:rails_mvc+, +:rails_way+): conventional MVC that keeps
  #   controller APIs out of models and services. Options +components:+,
  #   +controller_api:+, +share_helpers:+.
  # - +:rails_strict+: +:rails+ plus a cycle check and a concern independence
  #   check. Adds option +concerns:+.
  # - +:vanilla_rails+: +:rails+ plus empty-directory rules for the 37signals
  #   style (forbidding +app/services+, +app/forms+, +app/policies+, and more)
  #   and the concern independence check. Options +components:+, +empty:+,
  #   +controller_api:+, +share_helpers:+, +concerns:+.
  # - +:layered+ (alias +:rails_layered+): ordered layers that may only depend
  #   inward, with a cycle check. Option +layers:+ (order matters).
  # - +:hexagonal+ (alias +:rails_hexagonal+): ports and adapters, keeping the
  #   domain away from adapters. Options +application:+, +domain:+, +ports:+,
  #   +adapters:+.
  # - +:clean+ (alias +:rails_clean+): clean architecture layers. Options
  #   +frameworks:+, +interface_adapters:+, +use_cases:+, +entities:+.
  # - +:modular_monolith+ (alias +:bounded_contexts+): named packages with
  #   per-package allowlists and optional public APIs. Options +components:+
  #   (required), +allow:+, +public:+.
  # - +:cqrs+ (alias +:rails_cqrs+): separates commands from queries and keeps
  #   writes out of queries. Options +commands:+, +queries:+, +read_models:+,
  #   +mutating_methods:+.
  # - +:event_driven+ (alias +:rails_event_driven+): events, publishers, and
  #   subscribers. Options +events:+, +publishers:+, +subscribers:+.
  # - +:ruby_conventions+: generic Ruby naming idioms (no +get_+/+set_+, no +is_+
  #   prefix), applied project-wide. Adds no components, so it composes with any
  #   other architecture. No options.
  #
  # See the guides at https://archspecrb.dev/architectures/ for each in depth.
  module Architectures
    extend self

    DEFAULT_LAYERED = {
      interface: 'app/controllers/**/*.rb',
      application: %w[app/services/**/*.rb app/jobs/**/*.rb app/mailers/**/*.rb],
      domain: 'app/models/**/*.rb'
    }.freeze

    DEFAULT_RAILS_MVC = {
      controllers: 'app/controllers/**/*.rb',
      models: 'app/models/**/*.rb',
      helpers: 'app/helpers/**/*.rb',
      mailers: 'app/mailers/**/*.rb',
      jobs: 'app/jobs/**/*.rb',
      services: 'app/services/**/*.rb'
    }.freeze

    DEFAULT_HEXAGONAL = {
      application: %w[app/services/**/*.rb app/use_cases/**/*.rb],
      domain: 'app/domain/**/*.rb',
      ports: 'app/ports/**/*.rb',
      adapters: %w[app/adapters/**/*.rb app/integrations/**/*.rb app/infrastructure/**/*.rb]
    }.freeze

    DEFAULT_CLEAN = {
      frameworks: %w[app/controllers/**/*.rb app/jobs/**/*.rb app/mailers/**/*.rb],
      interface_adapters: %w[app/adapters/**/*.rb app/presenters/**/*.rb app/serializers/**/*.rb],
      use_cases: %w[app/use_cases/**/*.rb app/services/**/*.rb],
      entities: %w[app/entities/**/*.rb app/domain/**/*.rb app/models/**/*.rb]
    }.freeze

    DEFAULT_CQRS = {
      commands: 'app/commands/**/*.rb',
      queries: 'app/queries/**/*.rb',
      read_models: 'app/read_models/**/*.rb'
    }.freeze

    DEFAULT_EVENT_DRIVEN = {
      events: 'app/events/**/*.rb',
      publishers: 'app/publishers/**/*.rb',
      subscribers: 'app/subscribers/**/*.rb'
    }.freeze

    VANILLA_RAILS_EMPTY = {
      services: ['app/services/**/*.rb', 'behavior belongs on models, not service objects'],
      forms: ['app/forms/**/*.rb', 'use strong parameters and model validations'],
      policies: ['app/policies/**/*.rb', 'authorization is predicate methods on models'],
      decorators: ['app/decorators/**/*.rb', 'use helpers and ERB partials'],
      presenters: ['app/presenters/**/*.rb', 'presentation objects are POROs in app/models'],
      view_components: ['app/components/**/*.rb', 'use helpers and ERB partials']
    }.freeze

    DEFAULT_CONCERNS = 'app/**/concerns/**/*.rb'

    CONTROLLER_METHODS = %i[render redirect_to params session cookies flash].freeze
    MUTATING_METHODS = %i[
      create create!
      delete delete_all
      destroy destroy!
      insert insert!
      save save!
      update update! update_attribute update_attributes update_columns
      upsert upsert!
    ].freeze

    # Applies the named preset to +dsl+, forwarding +options+ to it. Raises
    # ArchSpec::Error for an unknown name. Called by
    # ArchSpec::DSL::Context#architecture, so you rarely call it directly.
    def apply(name, dsl, **options)
      case name.to_sym
      when :rails, :rails_mvc, :rails_way
        rails_mvc(
          dsl,
          components: options.fetch(:components, DEFAULT_RAILS_MVC),
          controller_api: options.fetch(:controller_api, CONTROLLER_METHODS),
          share_helpers: options.fetch(:share_helpers, false)
        )
      when :rails_strict
        rails_strict(
          dsl,
          components: options.fetch(:components, DEFAULT_RAILS_MVC),
          controller_api: options.fetch(:controller_api, CONTROLLER_METHODS),
          share_helpers: options.fetch(:share_helpers, false),
          concerns: options.fetch(:concerns, DEFAULT_CONCERNS)
        )
      when :vanilla_rails
        vanilla_rails(
          dsl,
          components: options.fetch(:components, DEFAULT_RAILS_MVC),
          empty: options.fetch(:empty, VANILLA_RAILS_EMPTY),
          controller_api: options.fetch(:controller_api, CONTROLLER_METHODS),
          share_helpers: options.fetch(:share_helpers, false),
          concerns: options.fetch(:concerns, DEFAULT_CONCERNS)
        )
      when :layered, :rails_layered
        layered(dsl, layers: options.fetch(:layers, DEFAULT_LAYERED))
      when :hexagonal, :rails_hexagonal
        hexagonal(dsl, **with_defaults(DEFAULT_HEXAGONAL, options))
      when :clean, :rails_clean
        clean(dsl, **with_defaults(DEFAULT_CLEAN, options))
      when :modular_monolith, :bounded_contexts
        modular_monolith(
          dsl,
          components: options.fetch(:components),
          allow: options.fetch(:allow, {}),
          public: options.fetch(:public, {})
        )
      when :cqrs, :rails_cqrs
        cqrs(dsl, **with_defaults(DEFAULT_CQRS, options))
      when :event_driven, :rails_event_driven
        event_driven(dsl, **with_defaults(DEFAULT_EVENT_DRIVEN, options))
      when :ruby_conventions
        ruby_conventions(dsl)
      else
        raise Error, "Unknown ArchSpec architecture: #{name.inspect}"
      end
    end

    def rails_mvc(dsl, components:, controller_api: CONTROLLER_METHODS, share_helpers: false)
      components = normalize_map(components)
      define_components(dsl, components)

      forbidden = share_helpers ? %i[controllers] : %i[controllers helpers]
      proxy_for(dsl, :controllers).can_only_use(*components.keys & %i[models services helpers mailers jobs])
      proxy_for(dsl, :models).cannot_use(*components.keys & forbidden)
      proxy_for(dsl, :services).cannot_use(*components.keys & forbidden)

      return if controller_api.empty?

      proxy_for(dsl, :models).cannot_call(*controller_api, receiver: :none)
      proxy_for(dsl, :services).cannot_call(*controller_api, receiver: :none)
    end

    def rails_strict(dsl, components:, controller_api: CONTROLLER_METHODS, share_helpers: false, concerns: DEFAULT_CONCERNS)
      components = normalize_map(components)
      rails_mvc(dsl, components: components, controller_api: controller_api, share_helpers: share_helpers)
      dsl.no_cycles(among: components.keys)
      independent_concerns(dsl, concerns)
    end

    def vanilla_rails(dsl, components:, empty:, controller_api: CONTROLLER_METHODS, share_helpers: false,
                      concerns: DEFAULT_CONCERNS)
      rails_mvc(dsl, components: components, controller_api: controller_api, share_helpers: share_helpers)

      empty.each do |name, (pattern, reason)|
        dsl.component(name, in: pattern).must_be_empty(because: reason)
      end

      independent_concerns(dsl, concerns)
    end

    def layered(dsl, layers:)
      ordered = normalize_map(layers)
      define_components(dsl, ordered)
      names = ordered.keys

      names.each_with_index do |name, index|
        allowed = names[(index + 1)..] || []
        proxy_for(dsl, name).can_only_use(*allowed)
      end

      dsl.no_cycles(among: names)
    end

    def hexagonal(dsl, application:, domain:, ports:, adapters:)
      roles = normalize_map(
        application: application,
        domain: domain,
        ports: ports,
        adapters: adapters
      )
      define_components(dsl, roles)

      proxy_for(dsl, :application).can_only_use :domain, :ports
      proxy_for(dsl, :domain).cannot_use :adapters
      proxy_for(dsl, :ports).cannot_use :adapters
      proxy_for(dsl, :adapters).can_only_use :application, :domain, :ports
      dsl.no_cycles(among: roles.keys)
    end

    def clean(dsl, frameworks:, interface_adapters:, use_cases:, entities:)
      layered(
        dsl,
        layers: {
          frameworks: frameworks,
          interface_adapters: interface_adapters,
          use_cases: use_cases,
          entities: entities
        }
      )
    end

    def modular_monolith(dsl, components:, allow: {}, public: {})
      components = normalize_map(components)
      define_components(dsl, components)

      components.each_key do |name|
        allowed = Array(allow[name] || allow[name.to_s])
        proxy_for(dsl, name).can_only_use(*allowed)

        patterns = Array(public[name] || public[name.to_s])
        proxy_for(dsl, name).public_api(*patterns) if patterns.any?
      end

      dsl.no_cycles(among: components.keys)
    end

    def cqrs(dsl, commands:, queries:, read_models: nil, mutating_methods: MUTATING_METHODS)
      components = normalize_map(commands: commands, queries: queries)
      components[:read_models] = read_models if read_models
      define_components(dsl, components)

      proxy_for(dsl, :commands).cannot_use :queries
      proxy_for(dsl, :queries).cannot_use :commands
      proxy_for(dsl, :queries).cannot_call(*mutating_methods)
      dsl.no_cycles(among: components.keys)
    end

    def event_driven(dsl, events:, publishers:, subscribers:)
      roles = normalize_map(events: events, publishers: publishers, subscribers: subscribers)
      define_components(dsl, roles)

      proxy_for(dsl, :events).cannot_use :publishers, :subscribers
      proxy_for(dsl, :publishers).can_only_use :events
      proxy_for(dsl, :subscribers).can_only_use :events
      dsl.no_cycles(among: roles.keys)
    end

    # Applies the generic Ruby naming idioms project-wide: no +get_+/+set_+
    # accessors and no +is_+ predicate prefix. Adds no components, so it composes
    # with any other architecture. Project-specific conventions (the +with_x+ /
    # +without_x+ pairing, the +supports_*?+ ban) stay opt-in through the
    # +methods.matching(...)+ primitives.
    def ruby_conventions(dsl)
      forbid_name(dsl, /\A(get|set)_/, 'use attr_ readers and writers or plain names, not get_/set_')
      forbid_name(dsl, /\Ais_/, 'name predicates with a trailing ? and no is_ prefix (has_ is fine)')
    end

    private

    def forbid_name(dsl, regex, reason)
      dsl.rule(
        Rules::NamingRule.new(
          source: nil,
          selector: Rules::Naming::NameSelector.new(regex),
          constraint: Rules::Naming::Forbidden.new(because: reason)
        )
      )
    end

    def with_defaults(defaults, options)
      defaults.merge(options)
    end

    def normalize_map(map)
      map.to_h.transform_keys(&:to_sym)
    end

    def define_components(dsl, components)
      components.each do |name, selector|
        define_component(dsl, name, selector)
      end
    end

    def define_component(dsl, name, selector)
      if selector.is_a?(Hash)
        dsl.component(
          name,
          in: selector[:in] || selector[:files],
          namespace: selector[:namespace],
          constants: selector[:constants]
        )
      else
        dsl.component(name, in: selector)
      end
    end

    def proxy_for(dsl, name)
      DSL::ComponentProxy.new(dsl, name)
    end

    def independent_concerns(dsl, pattern)
      return unless pattern

      dsl.component(:concerns, in: pattern).cannot_reference_includers
      # Controllers carry an allowlist, so let them include concerns too.
      proxy_for(dsl, :controllers).can_only_use(:concerns)
    end
  end
end
