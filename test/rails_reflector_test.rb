# frozen_string_literal: true

require 'test_helper'
require 'active_record'
require 'stringio'

class RailsReflectorTest < ArchSpecTest
  def teardown
    Object.send(:remove_const, :ReflectionFixture) if Object.const_defined?(:ReflectionFixture)
    super
  end

  def test_real_reflection_resolves_namespaces_overrides_and_polymorphic_gaps
    with_project do |root|
      path = "#{root}/app/models/records.rb"
      write path, <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base
          end
          class Invoice < ActiveRecord::Base
            belongs_to :client, class_name: 'ReflectionFixture::Customer'
            belongs_to :attachable, polymorphic: true
          end
          class SpecialInvoice < Invoice
          end
        end
      RUBY
      load path
      graph = analyze(root)
      document = reflect(graph, [ReflectionFixture::Invoice, ReflectionFixture::SpecialInvoice])
      assert_equal [['ReflectionFixture::Invoice', 'ReflectionFixture::Customer']],
                   document['references'].map { |entry| entry.values_at('source', 'target') }
      assert_equal 5, document['references'].first['line']
      assert_equal ['polymorphic association ReflectionFixture::Invoice.attachable'], document['gaps'].map { |gap| gap['message'] }
      assert_equal [%w[attachable attachable=], %w[client client=]], document['methods'].map { |entry| entry['names'] }
      ArchSpec::Facts.write("#{root}/archspec_facts/rails.yml", document)
      definition = ArchSpec.define do
        component :invoices, constants: 'ReflectionFixture::Invoice'
        component :customers, constants: 'ReflectionFixture::Customer'
        invoices.cannot_use :customers
        facts
      end
      diagnostics = diagnostics_for(definition, root)
      assert_equal ['dependencies.forbid'], diagnostics.map(&:rule)
      assert_equal 'ReflectionFixture::Invoice references ReflectionFixture::Customer', diagnostics.first.evidence
    end
  end

  def test_associations_in_concern_callbacks_are_attributed_to_the_model
    with_project do |root|
      write "#{root}/app/models/concerns/owned.rb", <<~RUBY
        module ReflectionFixture
          module Owned
            extend ActiveSupport::Concern
            included do
              belongs_to :customer, class_name: 'ReflectionFixture::Customer'
            end
          end
        end
      RUBY
      write "#{root}/app/models/records.rb", <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base; end
          class Invoice < ActiveRecord::Base
            include Owned
          end
        end
      RUBY
      load "#{root}/app/models/concerns/owned.rb"
      load "#{root}/app/models/records.rb"
      document = reflect(analyze(root), [ReflectionFixture::Invoice])
      assert_empty document['gaps']
      assert_equal 'ReflectionFixture::Invoice', document['references'].first['source']
      assert_equal 5, document['references'].first['line']
      assert_equal 'app/models/concerns/owned.rb', document['references'].first['path']
      assert_equal 'app/models/records.rb', document['references'].first['source_path']
      ArchSpec::Facts.write("#{root}/archspec_facts/rails.yml", document)
      definition = ArchSpec.define do
        component :invoices, constants: 'ReflectionFixture::Invoice'
        component :customers, constants: 'ReflectionFixture::Customer'
        invoices.cannot_use :customers
        facts
      end
      assert_equal ['dependencies.forbid'], diagnostics_for(definition, root).map(&:rule)
    end
  end

  def test_ambiguous_and_dynamic_declarations_are_reported_without_guessing
    with_project do |root|
      path = "#{root}/app/models/records.rb"
      write path, <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base; end
          class Invoice < ActiveRecord::Base
            belongs_to :client, class_name: 'ReflectionFixture::Customer'
            belongs_to :client, class_name: 'ReflectionFixture::Customer'
            association_name = :customer
            belongs_to association_name, class_name: 'ReflectionFixture::Customer'
          end
        end
      RUBY
      capture_io { load path }
      document = reflect(analyze(root), [ReflectionFixture::Invoice])
      assert_empty document['references']
      assert_equal 2, document['gaps'].size
      assert document['gaps'].all? { |gap| gap['message'].include?('no unique literal declaration') }
    end
  end

  def test_through_associations_use_the_resolved_target
    with_project do |root|
      path = "#{root}/app/models/records.rb"
      write path, <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base; end
          class Membership < ActiveRecord::Base
            belongs_to :customer
          end
          class Account < ActiveRecord::Base
            has_many :memberships
            has_many :customers, through: :memberships
          end
        end
      RUBY
      load path
      document = reflect(analyze(root), [ReflectionFixture::Account])
      assert_empty document['gaps']
      assert_equal %w[ReflectionFixture::Customer ReflectionFixture::Membership], document['references'].map { |entry| entry['target'] }
    end
  end

  def test_reflect_command_runs_an_explicit_subprocess_and_preserves_facts_on_failure
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\nfacts\n"
      write "#{root}/app/models/records.rb", <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base; end
          class Invoice < ActiveRecord::Base
            belongs_to :customer
          end
        end
      RUBY
      # A minimal Rails stand-in keeps the process boundary real: the
      # producer boots it, then reflects on real Active Record models.
      write "#{root}/config/environment.rb", <<~RUBY
        require 'active_record'
        abort 'wrong environment' unless ENV['RAILS_ENV'] == 'test'
        module Rails
          def self.env = ENV.fetch('RAILS_ENV')
          def self.application = self
          def self.eager_load!
            Dir['app/models/**/*.rb'].sort.each { |path| load path }
          end
        end
      RUBY
      output = StringIO.new
      error = StringIO.new
      argv = ['reflect', '--config', "#{root}/Archspec.rb", '--environment', 'test']
      assert_equal 0, ArchSpec::CLI.run(argv, output: output, error: error), error.string
      assert_match(%r{Updated archspec_facts/rails\.yml: 1 reference, 2 methods}, output.string)
      path = "#{root}/archspec_facts/rails.yml"
      previous = File.read(path)
      write "#{root}/config/environment.rb", "warn 'boot failed'; exit 1\n"
      assert_equal 1, ArchSpec::CLI.run(argv, output: StringIO.new, error: error)
      assert_match(/boot failed/, error.string)
      assert_equal previous, File.read(path)
    end
  end

  def test_unresolved_through_associations_are_gaps
    with_project do |root|
      path = "#{root}/app/models/records.rb"
      write path, <<~RUBY
        module ReflectionFixture
          class Invoice < ActiveRecord::Base
            has_many :customers, through: :missing_association
          end
        end
      RUBY
      load path
      document = reflect(analyze(root), [ReflectionFixture::Invoice])
      assert_empty document['references']
      assert_equal 1, document['gaps'].size
      assert_match(/unresolved association/, document['gaps'].first['message'])
    end
  end

  def test_custom_validators_become_references_at_their_declaration
    with_project do |root|
      write "#{root}/app/validators/email_validator.rb", <<~RUBY
        module ReflectionFixture
          class EmailValidator < ActiveModel::EachValidator
            def validate_each(record, attribute, value) = nil
          end
        end
      RUBY
      write "#{root}/app/models/records.rb", <<~RUBY
        module ReflectionFixture
          class Customer < ActiveRecord::Base
            validates :email, 'reflection_fixture/email': true, presence: true
          end
          class Supplier < ActiveRecord::Base
            validates_with EmailValidator, attributes: [:email]
          end
          class VipCustomer < Customer; end
        end
      RUBY
      load "#{root}/app/validators/email_validator.rb"
      load "#{root}/app/models/records.rb"
      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :validators, in: 'app/validators/**/*.rb'
        models.cannot_use :validators
        facts
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      models = [ReflectionFixture::Customer, ReflectionFixture::Supplier, ReflectionFixture::VipCustomer]
      facts = ArchSpec::Facts::Builder.new(graph, producer: 'rails')
      ArchSpec::RailsReflector.capture(facts, models: models, validated: models)
      document = facts.to_document
      assert_equal [['ReflectionFixture::Customer', 'ReflectionFixture::EmailValidator', 3]],
                   document['references'].map { |entry| entry.values_at('source', 'target', 'line') }
      assert_empty document['gaps']

      ArchSpec::Facts.write("#{root}/archspec_facts/rails.yml", document)
      diagnostics = diagnostics_for(definition, root)
      assert_equal [3, 6], diagnostics.map { |diagnostic| diagnostic.location.line }
      assert_equal ['dependencies.forbid'], diagnostics.map(&:rule).uniq
    end
  end

  def test_observed_conditional_concern_effects_settle_the_static_gap
    with_project do |root|
      write "#{root}/app/models/concerns/tracked.rb", <<~RUBY
        module ReflectionFixture
          module Audited
            def audit = nil
          end
          module Tracked
            extend ActiveSupport::Concern
            included do
              include Audited if name.end_with?('Order')
              if name.end_with?('Order')
                def tracked? = true
              end
            end
          end
        end
      RUBY
      write "#{root}/app/models/records.rb", <<~RUBY
        module ReflectionFixture
          class Order
            include Tracked
          end
          class Draft
            include Tracked
          end
        end
      RUBY
      load "#{root}/app/models/concerns/tracked.rb"
      load "#{root}/app/models/records.rb"
      definition = ArchSpec.define do
        component :orders, constants: 'ReflectionFixture::Order'
        component :drafts, constants: 'ReflectionFixture::Draft'
        component :audits, constants: 'ReflectionFixture::Audited'
        orders.cannot_use :audits
        drafts.cannot_use :audits
        orders.must_implement :tracked?
        drafts.must_implement :tracked?
        facts
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      assert_equal 1, graph.analysis_census[:dynamic_features]
      facts = ArchSpec::Facts::Builder.new(graph, producer: 'rails')
      ArchSpec::RailsReflector.concerns(facts)
      ArchSpec::Facts.write("#{root}/archspec_facts/rails.yml", facts.to_document)

      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      assert_equal 0, graph.analysis_census[:dynamic_features]
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
      assert_equal [['dependencies.forbid', 'ReflectionFixture::Order includes ReflectionFixture::Audited'],
                    ['protocol.must_implement', nil]],
                   diagnostics.map { |diagnostic| [diagnostic.rule, (diagnostic.evidence if diagnostic.rule.start_with?('dep'))] }
      assert_match(/Draft/, diagnostics.last.message)
      assert_equal 8, diagnostics.first.location.line
    end
  end

  def test_unattributable_conditional_effects_keep_the_gap
    with_project do |root|
      write "#{root}/app/models/concerns/tracked.rb", <<~RUBY
        module ReflectionFixture
          module Audited; end
          module Tracked
            extend ActiveSupport::Concern
            included do
              include Audited if name.end_with?('Order')
            end
          end
          module Logged
            extend ActiveSupport::Concern
            included do
              include Audited if name.end_with?('Order')
            end
          end
        end
      RUBY
      write "#{root}/app/models/records.rb", <<~RUBY
        module ReflectionFixture
          class Order
            include Tracked
            include Logged
          end
        end
      RUBY
      load "#{root}/app/models/concerns/tracked.rb"
      load "#{root}/app/models/records.rb"
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      facts = ArchSpec::Facts::Builder.new(graph, producer: 'rails')
      ArchSpec::RailsReflector.concerns(facts)
      document = facts.to_document
      assert_empty document['mixins']
      assert_empty document['resolves']
    end
  end

  def test_a_settled_conditional_callback_reports_consumers_added_later
    with_project do |root|
      write "#{root}/app/controllers/concerns/tracked.rb", <<~RUBY
        module ReflectionFixture
          module Audited; end
          module Tracked
            extend ActiveSupport::Concern
            included do
              include Audited if name.end_with?('Order')
            end
          end
        end
      RUBY
      write "#{root}/app/controllers/orders.rb", "module ReflectionFixture\n  class Order\n    include Tracked\n  end\nend\n"
      load "#{root}/app/controllers/concerns/tracked.rb"
      load "#{root}/app/controllers/orders.rb"
      definition = ArchSpec.define do
        component :controllers, in: 'app/controllers/**/*.rb'
        facts
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      facts = ArchSpec::Facts::Builder.new(graph, producer: 'rails')
      ArchSpec::RailsReflector.concerns(facts)
      ArchSpec::Facts.write("#{root}/archspec_facts/rails.yml", facts.to_document(sources: ['app/models/**/*.rb']))
      assert_empty diagnostics_for(definition, root)

      write "#{root}/app/controllers/back_order.rb", "module ReflectionFixture\n  class BackOrder\n    include Tracked\n  end\nend\n"
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      stale = ArchSpec::Evaluator.evaluate(definition, graph)
      assert_equal [['facts.stale', "#{root}/app/controllers/back_order.rb"]],
                   stale.map { |diagnostic| [diagnostic.rule, diagnostic.location.path] }
      assert_match(/have not observed this consumer of ReflectionFixture::Tracked/, stale.first.message)
      assert_equal 1, graph.analysis_census[:dynamic_features]

      File.delete("#{root}/app/controllers/back_order.rb")
      write "#{root}/app/controllers/orders.rb", "module ReflectionFixture\n  class Order\n    include Tracked\n    # edited\n  end\nend\n"
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      assert_equal ['facts.stale'], ArchSpec::Evaluator.evaluate(definition, graph).map(&:rule)
      assert_equal 1, graph.analysis_census[:dynamic_features]
    end
  end

  private

  def reflect(graph, models)
    facts = ArchSpec::Facts::Builder.new(graph, producer: 'rails')
    ArchSpec::RailsReflector.capture(facts, models: models, validated: [])
    facts.to_document(env: { 'RAILS_ENV' => 'test' })
  end

  def analyze(root)
    definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
    ArchSpec::Analyzer.analyze(definition, root: root)
  end
end
