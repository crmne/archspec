# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'

# A complete non-Rails integration: a small macro library, a producer that
# boots it in `archspec reflect`, and checks that consume what it observed.
class ProducerTest < ArchSpecTest
  def test_a_custom_producer_runs_through_reflect_and_feeds_checks
    with_project do |root|
      write_widget_project(root)

      output, error, status = cli(root, 'reflect')
      assert_equal 0, status, error
      assert_match(%r{Updated archspec_facts/widgets\.yml: 1 reference, 1 method}, output)
      assert_match(%r{Updated archspec_facts/audit\.yml: no facts}, output)

      output, _, status = cli(root, 'check', '--format', 'json')
      assert_equal 1, status
      violations = JSON.parse(output).fetch('violations')
      assert_equal ['dependencies.forbid'], violations.map { |violation| violation['rule'] }
      assert_equal 'Report references BillingService', violations.first['evidence']
      assert_equal ['app/widgets/report.rb', 3], violations.first.values_at('path', 'line')

      output, = cli(root, 'explain', 'Report')
      assert_match(/references BillingService \(from widgets facts\)/, output)
      assert_match(/instance methods: billing/, output)
    end
  end

  def test_producers_run_in_parallel_and_a_failure_keeps_the_other_results
    with_project do |root|
      write_widget_project(root)
      write "#{root}/lib/archspec/audit_facts.rb", <<~RUBY
        ArchSpec.producer(:audit) { capture { |_facts| raise ArchSpec::Error, 'audit log unavailable' } }
      RUBY

      output, error, status = cli(root, 'reflect')
      assert_equal 1, status
      assert_match(/audit producer failed \(exit 1\): audit log unavailable/, error)
      assert_match(/widgets\.yml/, output)
      assert File.file?("#{root}/archspec_facts/widgets.yml")

      _, error, status = cli(root, 'reflect', 'missing')
      assert_equal 64, status
      assert_match(/undeclared producer: missing/, error)
    end
  end

  def test_only_the_edited_file_goes_stale
    with_project do |root|
      write_widget_project(root)
      write "#{root}/app/services/audit_service.rb", "class AuditService; end\n"
      cli(root, 'reflect', 'widgets')

      write "#{root}/app/services/audit_service.rb", "class AuditService\n  def call = nil\nend\n"
      output, _, status = cli(root, 'check', '--format', 'json')
      assert_equal 1, status
      assert_equal ['dependencies.forbid'], JSON.parse(output).fetch('violations').map { |violation| violation['rule'] }

      write "#{root}/app/widgets/report.rb", "class Report\n  include Widgets\n  uses :billing\n  # edited\nend\n"
      output, _, status = cli(root, 'check', '--format', 'json')
      assert_equal 1, status
      violations = JSON.parse(output).fetch('violations')
      assert_equal [['facts.stale', 'app/widgets/report.rb']], violations.map { |violation| violation.values_at('rule', 'path') }
      assert_equal 'widgets facts are out of date for this file; run `archspec reflect`', violations.first['message']

      cli(root, 'reflect', 'widgets')
      write "#{root}/app/widgets/chart.rb", "class Chart\n  include Widgets\nend\n"
      output, = cli(root, 'check', '--format', 'json')
      assert_includes JSON.parse(output).fetch('violations').map { |violation| violation.values_at('rule', 'path') },
                      ['facts.stale', 'app/widgets/chart.rb']
    end
  end

  def test_global_inputs_and_environment_invalidate_the_whole_document
    with_project do |root|
      write_widget_project(root)
      cli(root, 'reflect', 'widgets')

      write "#{root}/config/widgets.yml", "billing: ledger\n"
      output, _, status = cli(root, 'check', 'app/services')
      assert_equal 1, status
      assert_match(%r{widgets facts are out of date: config/widgets\.yml changed; run `archspec reflect`}, output)

      _, error, status = cli(root, 'check', '--update-todo')
      assert_equal 1, status
      assert_match(/facts are out of date; run `archspec reflect` before updating the todo/, error)

      cli(root, 'reflect', 'widgets')
      with_env('WIDGETS_MODE' => 'strict') do
        output, _, status = cli(root, 'check')
        assert_equal 1, status
        assert_match(/captured with WIDGETS_MODE=relaxed, but it is strict/, output)
      end
      _, _, status = cli(root, 'check', 'app/services')
      assert_equal 0, status
    end
  end

  def test_producer_registration_and_declarations
    definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
    assert_nil definition.facts_path
    assert_equal({ 'rails' => nil }, definition.producers)

    definition = ArchSpec.define do
      component :models, in: 'app/models/**/*.rb'
      reflect :rails
      reflect :widgets, require: './lib/widgets_facts'
    end
    assert_equal 'archspec_facts', definition.facts_path
    assert_equal({ 'rails' => nil, 'widgets' => './lib/widgets_facts' }, definition.producers)

    producer = ArchSpec::Producer.new(:sample) do |sample|
      sample.inputs 'config/sample.yml'
      sample.sources 'app/samples/**/*.rb'
      sample.env 'SAMPLE_ENV'
      sample.capture { |_facts| nil }
    end
    assert_equal ArchSpec::Facts::DEFAULT_INPUTS + ['config/sample.yml'], producer.input_patterns
    assert_equal ['app/samples/**/*.rb'], producer.source_patterns
    assert_equal ['SAMPLE_ENV'], producer.env_names
    assert_raises(ArchSpec::Error) { ArchSpec::Producer.new(:empty) { inputs 'x' } }
    assert_raises(ArchSpec::Error) { ArchSpec::Producer.load(:missing, definition) }
  end

  def test_a_removed_file_drops_only_its_own_facts
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice\n  custom_macro :customer\nend\n"
      write "#{root}/app/models/customer.rb", "class Customer; end\n"
      write "#{root}/app/models/legacy.rb", "class Legacy\n  custom_macro :customer\nend\n"
      definition = ArchSpec.define do
        component :invoices, constants: 'Invoice'
        component :legacy, constants: 'Legacy'
        component :customers, constants: 'Customer'
        invoices.cannot_use :customers
        legacy.cannot_use :customers
        facts
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      facts = ArchSpec::Facts::Builder.new(graph, producer: 'macros')
      facts.reference(source: 'Invoice', target: 'Customer', location: ['app/models/invoice.rb', 2])
      facts.reference(source: 'Legacy', target: 'Customer', location: ['app/models/legacy.rb', 2])
      ArchSpec::Facts.write("#{root}/archspec_facts/macros.yml", facts.to_document(sources: ['app/models/**/*.rb']))

      File.delete("#{root}/app/models/legacy.rb")
      diagnostics = diagnostics_for(definition, root)
      assert_equal [['dependencies.forbid', 'Invoice references Customer']],
                   diagnostics.map { |diagnostic| [diagnostic.rule, diagnostic.evidence] }
    end
  end

  def test_an_exposure_goes_stale_with_its_owner
    with_project do |root|
      write "#{root}/lib/helpers.rb", "module Helpers\n  def label = nil\nend\n"
      write "#{root}/lib/panel.rb", "class Panel; end\n"
      definition = ArchSpec.define do
        component :library, in: 'lib/**/*.rb'
        facts
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      facts = ArchSpec::Facts::Builder.new(graph, producer: 'ui')
      facts.expose_methods(source: 'Helpers', owner: 'Panel', scope: :class)
      ArchSpec::Facts.write("#{root}/archspec_facts/ui.yml", facts.to_document)

      write "#{root}/lib/panel.rb", "class Board; end\n"
      diagnostics = diagnostics_for(definition, root)
      assert_equal [['facts.stale', "#{root}/lib/panel.rb"]],
                   diagnostics.map { |diagnostic| [diagnostic.rule, diagnostic.location.path] }
    end
  end

  private

  def write_widget_project(root)
    write "#{root}/Archspec.rb", <<~RUBY
      component :widgets, in: 'app/widgets/**/*.rb'
      component :services, in: 'app/services/**/*.rb'
      widgets.cannot_use :services
      reflect :widgets, require: './lib/archspec/widgets_facts'
      reflect :audit, require: './lib/archspec/audit_facts'
      todo 'archspec_todo.yml'
    RUBY
    write "#{root}/lib/widgets.rb", <<~RUBY
      # Resolves a service by convention when a widget declares it.
      module Widgets
        REGISTRY = {}

        def self.included(base) = base.extend(ClassMethods)

        module ClassMethods
          def uses(name)
            site = caller_locations(1, 1).first
            service = Object.const_get("\#{name.capitalize}Service")
            define_method(name) { service }
            Widgets::REGISTRY[self] = [name, service, site]
          end
        end
      end
    RUBY
    write "#{root}/app/widgets/report.rb", "class Report\n  include Widgets\n  uses :billing\nend\n"
    write "#{root}/app/services/billing_service.rb", "class BillingService; end\n"
    write "#{root}/lib/archspec/widgets_facts.rb", <<~RUBY
      ArchSpec.producer :widgets do
        inputs 'config/widgets.yml'
        sources 'app/widgets/**/*.rb'
        env 'WIDGETS_MODE'

        boot do |root|
          ENV['WIDGETS_MODE'] ||= 'relaxed'
          require File.join(root, 'lib/widgets')
          Dir[File.join(root, 'app/**/*.rb')].sort.each { |path| require path }
        end

        capture do |facts|
          Widgets::REGISTRY.each do |widget, (name, service, site)|
            facts.reference(source: widget, target: service, location: site)
            facts.methods(owner: widget.name, names: name, location: [site.path, site.lineno])
          end
        end
      end
    RUBY
    write "#{root}/lib/archspec/audit_facts.rb", "ArchSpec.producer(:audit) { capture { |_facts| nil } }\n"
  end

  def cli(root, *argv)
    output = StringIO.new
    error = StringIO.new
    status = ArchSpec::CLI.run([*argv, '--config', "#{root}/Archspec.rb"], output: output, error: error)
    [output.string, error.string, status]
  end

  def with_env(values)
    previous = values.keys.to_h { |key| [key, ENV.fetch(key, nil)] }
    values.each { |key, value| ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| ENV[key] = value }
  end
end
