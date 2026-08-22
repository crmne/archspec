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
  # - +:rails+: conventional MVC that keeps controller APIs out of models and
  #   services. Options +components:+, +controller_api:+, +share_helpers:+.
  # - +:rails_strict+: +:rails+ plus a cycle check and a concern independence
  #   check. Adds option +concerns:+.
  # - +:vanilla_rails+: +:rails+ plus empty-directory rules for the 37signals
  #   style (forbidding +app/services+, +app/forms+, +app/policies+, and more)
  #   and the concern independence check. Options +components:+, +empty:+,
  #   +controller_api:+, +share_helpers:+, +concerns:+.
  # - +:layered+: ordered layers that may only depend inward, with a cycle
  #   check. Option +layers:+ (order matters).
  # - +:hexagonal+: ports and adapters, keeping the domain away from adapters.
  #   Options +application:+, +domain:+, +ports:+, +adapters:+.
  # - +:clean+: clean architecture layers. Options +frameworks:+,
  #   +interface_adapters:+, +use_cases:+, +entities:+.
  # - +:modular_monolith+: named packages with per-package allowlists and
  #   optional public APIs. Options +components:+ (required), +allow:+,
  #   +public:+.
  # - +:cqrs+: separates commands from queries and keeps writes out of queries.
  #   Options +commands:+, +queries:+, +read_models:+, +mutating_methods:+.
  # - +:event_driven+: events, publishers, and subscribers. Options +events:+,
  #   +publishers:+, +subscribers:+.
  # - +:ruby_conventions+: generic Ruby naming idioms (no +get_+/+set_+, no +is_+
  #   prefix), applied project-wide. Adds no components, so it composes with any
  #   other architecture. No options.
  #
  # See the {architecture guides}[https://archspecrb.dev/architectures/] for
  # each preset in depth.
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

    # The reason each preset rule prints with its findings, one line per rule,
    # taken from the preset's guide.
    REASONS = {
      controllers_reach: 'controllers orchestrate a request; models, services, helpers, mailers and jobs are all they reach',
      stay_out_of_controllers: 'models and services run outside a request too, so nothing in them may know the controller',
      controller_api: 'render, redirect_to, params, session, cookies and flash exist only inside a request',
      no_cycles: 'two components that depend on each other change as one unit in practice',
      concerns: 'a concern that names its includer knows who uses it, which couples the two',
      layered: 'a layer depends inward only; the layer below never knows the one above',
      hexagonal_application: 'the application reaches the outside world through ports, never through an adapter',
      hexagonal_domain: 'the domain knows nothing of the outside world',
      hexagonal_ports: 'ports are the interfaces adapters implement; the dependency runs the other way',
      hexagonal_adapters: 'an adapter plugs into the application; adapters never depend on each other',
      modular_allow: 'a package reaches only the packages it declares',
      modular_public: 'only the public surface of a package is reached from outside it',
      cqrs_split: 'commands and queries stay apart so reads and writes can change separately',
      cqrs_reads: 'a query never writes',
      events: 'an event knows nothing of who publishes or subscribes to it',
      event_parties: 'publishers and subscribers meet only through events'
    }.freeze
    MUTATING_METHODS = %i[
      create create!
      delete delete_all
      destroy destroy!
      insert insert!
      save save!
      update update! update_attribute update_attributes update_columns
      upsert upsert!
    ].freeze

    # Every option each architecture accepts, with its default. The single
    # source of truth for #apply: option validation checks these keys, and the
    # architecture methods receive these values merged with the caller's.
    DEFAULTS = {
      rails: {
        components: DEFAULT_RAILS_MVC,
        controller_api: CONTROLLER_METHODS,
        share_helpers: false
      },
      rails_strict: {
        components: DEFAULT_RAILS_MVC,
        controller_api: CONTROLLER_METHODS,
        share_helpers: false,
        concerns: DEFAULT_CONCERNS
      },
      vanilla_rails: {
        components: DEFAULT_RAILS_MVC,
        empty: VANILLA_RAILS_EMPTY,
        controller_api: CONTROLLER_METHODS,
        share_helpers: false,
        concerns: DEFAULT_CONCERNS
      },
      layered: { layers: DEFAULT_LAYERED },
      hexagonal: DEFAULT_HEXAGONAL,
      clean: DEFAULT_CLEAN,
      modular_monolith: { components: nil, allow: {}, public: {} },
      cqrs: DEFAULT_CQRS.merge(mutating_methods: MUTATING_METHODS),
      event_driven: DEFAULT_EVENT_DRIVEN,
      ruby_conventions: {}
    }.freeze

    # Applies the named preset to +dsl+, forwarding +options+ to it. Raises
    # ArchSpec::Error for an unknown name. Called by
    # ArchSpec::DSL::Context#architecture, so you rarely call it directly.
    def apply(name, dsl, **options)
      name = architecture_name(name)
      defaults = DEFAULTS[name]
      raise Error, "unknown architecture: #{name.inspect}" unless defaults

      validate_options!(name, defaults, options)
      send(name, dsl, **defaults.merge(options))
    end

    def rails(dsl, components:, controller_api:, share_helpers:)
      components = normalize_map(components)
      missing = %i[controllers models] - components.keys
      if missing.any?
        raise Error, "the rails architectures need controllers and models components, missing: #{missing.join(', ')}"
      end

      define_components(dsl, components)

      forbidden = (share_helpers ? %i[controllers] : %i[controllers helpers]) & components.keys
      proxy_for(dsl, :controllers).can_only_use(*components.keys & %i[models services helpers mailers jobs],
                                                because: REASONS[:controllers_reach])

      (%i[models services] & components.keys).each do |name|
        proxy = proxy_for(dsl, name)
        proxy.cannot_use(*forbidden, because: REASONS[:stay_out_of_controllers])
        proxy.cannot_call(*controller_api, receiver: :none, because: REASONS[:controller_api]) unless controller_api.empty?
      end
    end

    def rails_strict(dsl, components:, controller_api:, share_helpers:, concerns:)
      components = normalize_map(components)
      rails(dsl, components: components, controller_api: controller_api, share_helpers: share_helpers)
      dsl.no_cycles(among: components.keys, because: REASONS[:no_cycles])
      independent_concerns(dsl, concerns)
    end

    def vanilla_rails(dsl, components:, empty:, controller_api:, share_helpers:, concerns:)
      rails(dsl, components: components, controller_api: controller_api, share_helpers: share_helpers)

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
        proxy_for(dsl, name).can_only_use(*allowed, because: REASONS[:layered])
      end

      dsl.no_cycles(among: names, because: REASONS[:no_cycles])
    end

    def hexagonal(dsl, application:, domain:, ports:, adapters:)
      roles = normalize_map(
        application: application,
        domain: domain,
        ports: ports,
        adapters: adapters
      )
      define_components(dsl, roles)

      proxy_for(dsl, :application).can_only_use :domain, :ports, because: REASONS[:hexagonal_application]
      proxy_for(dsl, :domain).cannot_use :adapters, because: REASONS[:hexagonal_domain]
      proxy_for(dsl, :ports).cannot_use :adapters, because: REASONS[:hexagonal_ports]
      proxy_for(dsl, :adapters).can_only_use :application, :domain, :ports, because: REASONS[:hexagonal_adapters]
      dsl.no_cycles(among: roles.keys, because: REASONS[:no_cycles])
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
      raise Error, 'architecture :modular_monolith requires the components: option' unless components

      components = normalize_map(components)
      define_components(dsl, components)

      components.each_key do |name|
        allowed = Array(allow[name] || allow[name.to_s])
        proxy_for(dsl, name).can_only_use(*allowed, because: REASONS[:modular_allow])

        patterns = Array(public[name] || public[name.to_s])
        proxy_for(dsl, name).public_api(*patterns, because: REASONS[:modular_public]) if patterns.any?
      end

      dsl.no_cycles(among: components.keys, because: REASONS[:no_cycles])
    end

    def cqrs(dsl, commands:, queries:, read_models:, mutating_methods:)
      components = normalize_map(commands: commands, queries: queries)
      components[:read_models] = read_models if read_models
      define_components(dsl, components)

      proxy_for(dsl, :commands).cannot_use :queries, because: REASONS[:cqrs_split]
      proxy_for(dsl, :queries).cannot_use :commands, because: REASONS[:cqrs_split]
      proxy_for(dsl, :queries).cannot_call(*mutating_methods, because: REASONS[:cqrs_reads])
      dsl.no_cycles(among: components.keys, because: REASONS[:no_cycles])
    end

    def event_driven(dsl, events:, publishers:, subscribers:)
      roles = normalize_map(events: events, publishers: publishers, subscribers: subscribers)
      define_components(dsl, roles)

      proxy_for(dsl, :events).cannot_use :publishers, :subscribers, because: REASONS[:events]
      proxy_for(dsl, :publishers).can_only_use :events, because: REASONS[:event_parties]
      proxy_for(dsl, :subscribers).can_only_use :events, because: REASONS[:event_parties]
      dsl.no_cycles(among: roles.keys, because: REASONS[:no_cycles])
    end

    # Applies the generic Ruby naming idioms project-wide: no +get_+/+set_+
    # accessors and no +is_+ predicate prefix. Adds no components, so it composes
    # with any other architecture. Project-specific conventions (the +with_x+ /
    # +without_x+ pairing, the +supports_*?+ ban) stay opt-in through the
    # +method_names.matching(...)+ primitives.
    def ruby_conventions(dsl)
      %i[instance class].each do |scope|
        forbid_name(dsl, /\A(get|set)_/, 'use attr_ readers and writers or plain names, not get_/set_', scope: scope)
        forbid_name(dsl, /\Ais_/, 'name predicates with a trailing ? and no is_ prefix (has_ is fine)', scope: scope)
      end
    end

    private

    def architecture_name(name)
      name.to_sym
    rescue NoMethodError
      raise Error, "unknown architecture: #{name.inspect}"
    end

    def validate_options!(name, defaults, options)
      unknown = options.keys - defaults.keys
      return if unknown.empty?

      label = unknown.length == 1 ? 'option' : 'options'
      names = unknown.map { |option| "#{option}:" }.sort.join(', ')
      raise Error, "unknown #{label} for architecture :#{name}: #{names}"
    end

    def forbid_name(dsl, regex, reason, scope:)
      dsl.rule(
        Rules::NamingRule.new(
          source: nil,
          selector: Rules::Naming::NameSelector.new(regex),
          constraint: Rules::Naming::Forbidden.new(because: reason),
          scope: scope
        )
      )
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
          except: selector[:except],
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

      dsl.component(:concerns, in: pattern).cannot_reference_includers(because: REASONS[:concerns])
      # Controllers carry an allowlist, so let them include concerns too.
      proxy_for(dsl, :controllers).can_only_use(:concerns)
    end
  end
end
