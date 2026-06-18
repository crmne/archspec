# frozen_string_literal: true

module ArchSpec
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

    def apply(name, dsl, **options)
      case name.to_sym
      when :rails, :rails_mvc, :rails_way
        rails_mvc(dsl, components: options.fetch(:components, DEFAULT_RAILS_MVC))
      when :rails_strict
        rails_strict(dsl, components: options.fetch(:components, DEFAULT_RAILS_MVC))
      when :vanilla_rails
        vanilla_rails(
          dsl,
          components: options.fetch(:components, DEFAULT_RAILS_MVC),
          empty: options.fetch(:empty, VANILLA_RAILS_EMPTY)
        )
      when :layered, :rails_layered
        layered(dsl, layers: options.fetch(:layers, DEFAULT_LAYERED))
      when :hexagonal, :rails_hexagonal
        hexagonal(dsl, **with_defaults(DEFAULT_HEXAGONAL, options))
      when :clean, :rails_clean
        clean(dsl, **with_defaults(DEFAULT_CLEAN, options))
      when :modular_monolith, :bounded_contexts
        modular_monolith(dsl, components: options.fetch(:components), allow: options.fetch(:allow, {}))
      when :cqrs, :rails_cqrs
        cqrs(dsl, **with_defaults(DEFAULT_CQRS, options))
      when :event_driven, :rails_event_driven
        event_driven(dsl, **with_defaults(DEFAULT_EVENT_DRIVEN, options))
      else
        raise Error, "Unknown ArchSpec architecture: #{name.inspect}"
      end
    end

    def rails_mvc(dsl, components:)
      components = normalize_map(components)
      define_components(dsl, components)

      proxy_for(dsl, :controllers).can_use(*components.keys & %i[models services helpers mailers jobs])
      proxy_for(dsl, :models).cannot_use(*components.keys & %i[controllers helpers])
      proxy_for(dsl, :services).cannot_use(*components.keys & %i[controllers helpers])
      proxy_for(dsl, :models).cannot_call(*CONTROLLER_METHODS)
      proxy_for(dsl, :services).cannot_call(*CONTROLLER_METHODS)
    end

    def rails_strict(dsl, components:)
      components = normalize_map(components)
      rails_mvc(dsl, components: components)
      dsl.verify_zeitwerk_names!
      dsl.no_cycles!(among: components.keys)
    end

    def vanilla_rails(dsl, components:, empty:)
      rails_mvc(dsl, components: components)

      empty.each do |name, (pattern, reason)|
        dsl.component(name, in: pattern).must_be_empty(because: reason)
      end
    end

    def layered(dsl, layers:)
      ordered = normalize_map(layers)
      define_components(dsl, ordered)
      names = ordered.keys

      names.each_with_index do |name, index|
        allowed = names[(index + 1)..] || []
        proxy_for(dsl, name).can_use(*allowed)
      end

      dsl.no_cycles!(among: names)
    end

    def hexagonal(dsl, application:, domain:, ports:, adapters:)
      roles = normalize_map(
        application: application,
        domain: domain,
        ports: ports,
        adapters: adapters
      )
      define_components(dsl, roles)

      proxy_for(dsl, :application).can_use :domain, :ports
      proxy_for(dsl, :domain).cannot_use :adapters
      proxy_for(dsl, :ports).cannot_use :adapters
      proxy_for(dsl, :adapters).can_use :application, :domain, :ports
      dsl.no_cycles!(among: roles.keys)
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

    def modular_monolith(dsl, components:, allow: {})
      components = normalize_map(components)
      define_components(dsl, components)

      components.each_key do |name|
        allowed = Array(allow[name] || allow[name.to_s])
        proxy_for(dsl, name).can_use(*allowed)
      end

      dsl.no_cycles!(among: components.keys)
    end

    def cqrs(dsl, commands:, queries:, read_models: nil, mutating_methods: MUTATING_METHODS)
      components = normalize_map(commands: commands, queries: queries)
      components[:read_models] = read_models if read_models
      define_components(dsl, components)

      proxy_for(dsl, :commands).cannot_use :queries
      proxy_for(dsl, :queries).cannot_use :commands
      proxy_for(dsl, :queries).cannot_call(*mutating_methods)
      dsl.no_cycles!(among: components.keys)
    end

    def event_driven(dsl, events:, publishers:, subscribers:)
      roles = normalize_map(events: events, publishers: publishers, subscribers: subscribers)
      define_components(dsl, roles)

      proxy_for(dsl, :events).cannot_use :publishers, :subscribers
      proxy_for(dsl, :publishers).can_use :events
      proxy_for(dsl, :subscribers).can_use :events
      dsl.no_cycles!(among: roles.keys)
    end

    private

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
  end
end
