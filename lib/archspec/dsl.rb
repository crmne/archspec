# frozen_string_literal: true

require 'pathname'

module ArchSpec
  # The ArchSpec DSL.
  #
  # An +Archspec.rb+ file is evaluated in this context, so every method here is
  # a top-level call in that file.
  module DSL
    # Raises when any of +names+ is not a declared component. Shared by the
    # top-level DSL and the component proxies.
    def self.assert_known_components!(definition, names, for_rule:)
      unknown = Array(names).flatten.compact.map(&:to_sym).reject { |name| definition.component?(name) }.uniq.sort
      return if unknown.empty?

      label = unknown.length == 1 ? 'component' : 'components'
      raise Error, "#{for_rule} references unknown #{label}: #{unknown.join(', ')}"
    end

    # The top-level DSL. Declare the project, its components, an architecture
    # preset, and global rules.
    #
    #   root "."
    #   source "app/**/*.rb", "lib/**/*.rb"
    #   ignore "app/legacy/**/*.rb"
    #   todo "archspec_todo.yml"
    #
    #   component :models, in: "app/models/**/*.rb"
    #   component :controllers, in: "app/controllers/**/*.rb"
    #   models.cannot_use :controllers
    #
    # Declaring a component defines a reader for it, so +models+ and
    # +controllers+ above return an ArchSpec::DSL::ComponentProxy you attach
    # rules to.
    module Context
      # Sets or reads the project root that file patterns resolve against.
      # Defaults to the directory of the +Archspec.rb+ file.
      def root(path = nil)
        return root_path unless path

        self.root_path = path.to_s
      end

      # Adds glob patterns for the files ArchSpec parses. Defaults cover
      # +app+, +lib+, packs, and engines. Component patterns are always
      # analyzed, so most projects never need this.
      def source(*patterns)
        add_source_patterns(patterns)
      end

      # Adds glob patterns for files to skip. Combines with the built-in
      # ignores for +.git+, +tmp+, +vendor+, and +node_modules+.
      def ignore(*patterns)
        add_ignore_patterns(patterns)
      end

      # Points at a todo file of accepted violations. Diagnostics recorded there
      # are subtracted from future runs, so you can adopt ArchSpec in an existing
      # app without fixing everything first, then burn the list down.
      #
      #   todo "archspec_todo.yml"
      #
      # Write or refresh it with <tt>archspec check --update-todo</tt>.
      def todo(path = 'archspec_todo.yml')
        self.todo_path = path.to_s
      end

      # Points at the directory of facts files merged before rules run, written
      # by <tt>archspec reflect</tt> or by another producer. Defaults to
      # +archspec_facts+; an absent directory is reported, never an error.
      # With <tt>associations: :static</tt> the Active Record associations
      # the parser can resolve without booting are merged on every check as
      # well, the same facts <tt>archspec reflect --static</tt> writes.
      #
      #   facts "archspec_facts"
      #   facts "archspec_facts", associations: :static
      # Names the directory where the facts extracted from each file are kept
      # between runs, keyed by the file's content and the gem version, so a
      # check re-reads only what changed. Off unless declared; the directory
      # ignores itself in git.
      #
      #   cache ".archspec/cache"
      def cache(path = Definition::DEFAULT_CACHE_DIRECTORY)
        self.cache_path = path.to_s
      end

      def facts(path = Facts::DEFAULT_DIRECTORY, associations: nil)
        unless associations.nil? || associations == :static
          raise Error, "facts associations: must be :static, got #{associations.inspect}"
        end

        self.facts_path = path.to_s
        self.static_associations = associations == :static
      end

      # Yields each subdirectory matching a glob, so you can declare one
      # component per engine or pack without hardcoding their names. Paths
      # resolve against the +Archspec.rb+ directory, not the working directory,
      # so it does not matter where +archspec+ is run from.
      #
      #   each_directory "engines/*" do |name, path|
      #     component name, in: "#{path}/**/*.rb"
      #   end
      #
      # Yields the directory basename and its root-relative path. Returns the
      # <tt>[name, path]</tt> pairs when called without a block.
      def each_directory(glob)
        base = absolute_root
        pairs = Dir.glob(File.join(base, glob)).select { |path| File.directory?(path) }.sort.map do |absolute|
          [File.basename(absolute), Pathname(absolute).relative_path_from(Pathname(base)).to_s]
        end

        return pairs unless block_given?

        pairs.each { |name, path| yield(name, path) }
      end

      # Declares a component: a named set of files, matched by glob, namespace,
      # or explicit constant.
      #
      #   component :services, in: "app/services/**/*.rb"
      #   component :domain, in: "app/models/**/*.rb", except: "app/models/**/*_workflow.rb"
      #   component :billing, namespace: "Billing"
      #   component :legacy, constants: %w[OldReport OldExport]
      #
      # +except:+ removes files from what +in:+ matched, so a handful of files
      # can form their own component with their own rules instead of a hole in
      # this one's allowlist. It never widens anything: the carved-out component
      # states its own dependencies.
      #
      # Returns an ArchSpec::DSL::ComponentProxy for attaching rules. The
      # component is also available by name later in the file.
      def component(name, in: nil, except: nil, namespace: nil, constants: nil)
        add_component(
          ComponentSpec.new(
            name,
            files: binding.local_variable_get(:in),
            except: except,
            namespace: namespace,
            constants: constants
          )
        )
        ComponentProxy.new(self, name)
      end

      # Applies a bundled architecture preset, defining its components and
      # rules together.
      #
      #   architecture :rails
      #   architecture :hexagonal
      #   architecture :modular_monolith, components: { ... }, allow: { ... }
      #
      # +preset+ is an alias. Use whichever word fits: +architecture+ reads well
      # for structural bundles like +:rails+, +preset+ for convention packs like
      # +:ruby_conventions+.
      #
      # See ArchSpec::Architectures for every preset and its options.
      def architecture(name, **options)
        Architectures.apply(name, self, **options)
      end

      alias preset architecture

      # Forbids dependency cycles between components. Pass +among:+ to limit the
      # check to a subset; omit it to check every declared component.
      #
      #   no_cycles
      #   no_cycles among: %i[billing catalog shared]
      #
      # Every rule-creating call takes +because:+, the reason printed with each
      # finding, and +since:+, a date from which the rule holds: a breach on a
      # line older than the date is reported under its own heading and does
      # not fail the check. Rule id: +dependencies.no_cycles+.
      def no_cycles(among: nil, because: nil, since: nil)
        DSL.assert_known_components!(self, among, for_rule: 'no_cycles') if among
        add_rule(Rules::NoCyclesRule.new(among: among, because: because, since: since))
      end

      # Adds a custom rule object. A rule responds to +id+ and
      # <tt>evaluate(graph)</tt>, returning ArchSpec::Diagnostic objects. Use
      # this to extend ArchSpec with project-specific checks.
      def rule(rule)
        add_rule(rule)
      end

      # Registers an output format under a name, selectable with
      # <tt>archspec check --format NAME</tt>. A formatter responds to
      # <tt>print(output, graph:, diagnostics:)</tt> and, to take part in a
      # baseline check, <tt>print_delta(output, graph:, diagnostics:, delta:,
      # mode:)</tt>. A shipped name registered again is replaced.
      #
      #   formatter :junit, JunitFormatter
      def formatter(name, formatter)
        raise Error, "formatter #{name.inspect} must respond to print" unless formatter.respond_to?(:print)

        add_formatter(name, formatter)
      end

      def method_missing(name, ...)
        return ComponentProxy.new(self, name) if component?(name)

        super
      end

      def respond_to_missing?(name, include_private = false)
        component?(name) || super
      end
    end

    # A handle to one component, returned by ArchSpec::DSL::Context#component
    # and by calling a declared component's name. Rule methods return +self+, so
    # they chain.
    #
    #   services.cannot_use(:controllers).cannot_call(:render, receiver: :none)
    #
    # Every rule method takes +because:+, the reason printed beside each
    # finding and carried in JSON, and +since:+, the date the rule holds from.
    # Neither enters a finding's fingerprint, so adding them to a rule the
    # team already runs moves no todo entry.
    class ComponentProxy
      attr_reader :definition, :name

      def initialize(definition, name)
        @definition = definition
        @name = name.to_sym
      end

      # Allowlists the components this one may depend on: only the listed
      # components are permitted, and a reference to any other declared
      # component fails. The mirror image of #can_only_be_used_by.
      #
      #   controllers.can_only_use :models, :services
      #
      # Rule id: +dependencies.allow+.
      def can_only_use(*targets, because: nil, since: nil)
        DSL.assert_known_components!(definition, targets, for_rule: "#{name}.can_only_use")
        add_rule(Rules::AllowDependenciesRule.new(name, targets, because: because, since: since))
        self
      end

      # Forbids depending on the named components. Narrower than #can_only_use:
      # only the listed components fail, other dependencies are left alone.
      #
      #   models.cannot_use :controllers, :helpers
      #
      # Rule id: +dependencies.forbid+.
      def cannot_use(*targets, because: nil, since: nil)
        DSL.assert_known_components!(definition, targets, for_rule: "#{name}.cannot_use")
        add_rule(Rules::ForbidDependenciesRule.new(name, targets, because: because, since: since))
        self
      end

      # Allowlists the components that may reference this one, the inverse of
      # #can_only_use. A reference from any other component fails. Use it to protect
      # a shared kernel or a component with a deliberately narrow audience.
      #
      #   shared_kernel.can_only_be_used_by :billing, :catalog
      #
      # Rule id: +dependencies.consumers+.
      def can_only_be_used_by(*consumers, because: nil, since: nil)
        DSL.assert_known_components!(definition, consumers, for_rule: "#{name}.can_only_be_used_by")
        add_rule(Rules::AllowedConsumersRule.new(name, consumers, because: because, since: since))
        self
      end

      # Forbids calling the named methods. By default any receiver matches, so
      # this catches +record.update+ and +cache.update+ alike. Pass
      # <tt>receiver: :none</tt> to match only bare, implicit-+self+ calls, which
      # is how the Rails presets keep the controller API out of models.
      #
      #   queries.cannot_call :save, :update, :destroy
      #   services.cannot_call :render, :params, receiver: :none
      #
      # A bare call to a method the component defines, inherits, or generates
      # with +attr_*+, Rails +attribute+, or +delegate+ is treated as its own API
      # and not flagged.
      # Rule id: +methods.forbid+.
      def cannot_call(*methods, receiver: :any, because: nil, since: nil)
        add_rule(Rules::CannotCallRule.new(name, methods, receiver: receiver, because: because, since: since))
        self
      end

      # Forbids defining the named methods in this component. Use it when the
      # method name itself is a design smell there, such as +call+ on a
      # component that should not hold command objects.
      #
      #   models.cannot_define :call
      #
      # Rule id: +methods.define_forbid+.
      def cannot_define(*methods, because: nil, since: nil)
        add_rule(Rules::CannotDefineMethodRule.new(name, methods, because: because, since: since))
        self
      end

      # Forbids the one-shot <tt>Thing.new(...).call</tt> pattern, where a class
      # is instantiated and immediately invoked. Use it to steer a component
      # toward plain methods over anonymous command objects.
      #
      # Rule id: +objects.instantiate_and_invoke_forbid+.
      def cannot_instantiate_and_invoke(because: nil, since: nil)
        add_rule(Rules::CannotInstantiateAndInvokeRule.new(name, because: because, since: since))
        self
      end

      # Forbids referencing the named constants or anything under them. Use this
      # when the boundary is a framework constant rather than a component.
      #
      #   models.cannot_reference_constants "ActionController", "ActionView"
      #
      # Rule id: +constants.forbid+.
      def cannot_reference_constants(*constants, because: nil, since: nil)
        add_rule(Rules::CannotReferenceConstantsRule.new(name, constants, because: because, since: since))
        self
      end

      # Marks part of the component as its public API. References from outside
      # must resolve to a public constant; everything else becomes private.
      #
      #   billing.public_api "packs/billing/app/public/**/*.rb"
      #   billing.public_api constants: "Billing::Api"
      #   billing.public_api namespace: "Billing::Public"
      #
      # +constants+ matches exact names, +namespace+ matches a name and its
      # children. Code inside the component may still reach its own internals.
      # Rule id: +dependencies.privacy+.
      def public_api(*patterns, constants: nil, namespace: nil, because: nil, since: nil)
        add_rule(Rules::PublicApiRule.new(name, files: patterns, constants: constants, namespaces: namespace,
                                                because: because, since: since))
        self
      end

      # Forbids a concern from referencing the constants that include it. A
      # concern that names its includer knows too much about who uses it, which
      # couples the two and defeats the point of extracting the concern.
      #
      #   component :model_concerns, in: "app/models/concerns/**/*.rb"
      #   model_concerns.cannot_reference_includers
      #
      # Rule id: +concerns.independence+.
      def cannot_reference_includers(because: nil, since: nil)
        add_rule(Rules::ConcernIndependenceRule.new(name, because: because, since: since))
        self
      end

      # Requires the component to hold no files. Use it to keep a directory
      # empty, such as +app/services+ in a vanilla Rails app, with a reason
      # shown in the diagnostic.
      #
      #   component(:services, in: "app/services/**/*.rb")
      #     .must_be_empty(because: "behavior belongs on models")
      #
      # Rule id: +components.empty+.
      def must_be_empty(because: nil, since: nil)
        add_rule(Rules::MustBeEmptyRule.new(name, because: because, since: since))
        self
      end

      # Requires every class in the component to implement all the named
      # methods. Methods inherited from resolvable superclasses or mixins
      # count. Pass <tt>scope: :class</tt> for a class-side protocol, which
      # counts class methods, methods from +extend+ed modules, and the
      # superclass chain's class methods.
      #
      #   commands.must_implement :perform
      #   jobs.must_implement :perform_later, scope: :class
      #
      # Rule id: +protocol.must_implement+.
      def must_implement(*methods, scope: :instance, because: nil, since: nil)
        raise Error, 'must_implement requires at least one method' if methods.flatten.compact.empty?

        methods.each do |method_name|
          add_rule(Rules::MustImplementRule.new(name, method_name, scope: scope, because: because, since: since))
        end
        self
      end

      # Requires every class in the component to implement at least one of the
      # named methods. Useful when a protocol allows either name. Takes the
      # same +scope:+ as +must_implement+.
      #
      #   commands.must_implement_one_of :perform, :call
      #
      # Rule id: +protocol.must_implement_one_of+.
      def must_implement_one_of(*methods, scope: :instance, because: nil, since: nil)
        add_rule(Rules::MustImplementOneOfRule.new(name, methods, scope: scope, because: because, since: since))
        self
      end

      # Starts a naming-convention rule over the component's defined, public
      # methods. Select the methods with +matching+, then assert something about
      # them. Every check is name-based and exact.
      #
      #   models.method_names.matching(/\A(get|set)_/).forbidden
      #   chat.method_names.matching(/\Awith_(?<base>.+)/).requires("without_%{base}")
      #   chat.method_names.matching(/\Awith_(?<b>.+)/).requires("%{b}", on: agent, scope: :class)
      #
      # Pass <tt>scope: :class</tt> to select class methods instead of instance
      # methods. See ArchSpec::Rules::Naming::Selected for the constraints
      # (+forbidden+, +requires+). Rule ids: +naming.forbidden+, +naming.requires+.
      def method_names(scope: :instance)
        Rules::Naming::Builder.new(self, scope: scope)
      end

      private

      def add_rule(rule)
        if rule.respond_to?(:merge_key)
          existing = definition.rules.find do |candidate|
            candidate.respond_to?(:merge_key) && candidate.merge_key == rule.merge_key
          end

          if existing
            existing.merge!(rule) if existing.respond_to?(:merge!)
            existing.merge_annotations!(rule) if existing.respond_to?(:merge_annotations!)
            return existing
          end
        end

        definition.add_rule(rule)
      end
    end
  end
end
