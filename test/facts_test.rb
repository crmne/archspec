# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class FactsTest < ArchSpecTest
  def test_generic_references_and_generated_methods_participate_in_rules
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice\n  custom_macro :customer\nend\n"
      write "#{root}/app/models/customer.rb", "class Customer; end\n"
      definition = definition_for_facts
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      document = document_for(graph)
      document['references'] << { 'source' => 'Invoice', 'target' => 'Customer', 'path' => 'app/models/invoice.rb', 'line' => 2 }
      document['methods'] << { 'owner' => 'Invoice', 'scope' => 'instance', 'names' => ['customer'],
                              'path' => 'app/models/invoice.rb', 'line' => 2 }
      ArchSpec::Facts.write("#{root}/archspec_facts/custom.yml", document)
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
      assert_equal ['dependencies.forbid'], diagnostics.map(&:rule)
      assert_equal 'Invoice references Customer', diagnostics.first.evidence
      assert_equal 2, diagnostics.first.location.line
      assert_includes graph.effective_instance_methods('Invoice').first, :customer
    end
  end

  def test_missing_facts_are_errors_and_stale_facts_fail_the_check
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice; end\n"
      definition = definition_for_facts
      assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(definition, root: root) }
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      path = "#{root}/archspec_facts/custom.yml"
      ArchSpec::Facts.write(path, document_for(graph))
      write "#{root}/app/models/new_model.rb", "class NewModel; end\n"
      stale = stale_diagnostics(definition, root)
      assert_equal [path], stale.map { |diagnostic| diagnostic.location.path }
      assert_match(/custom facts are out of date: source or configuration changed; run `archspec reflect`/,
                   stale.first.message)
    end
  end

  def test_configuration_and_dependency_changes_invalidate_snapshots
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice; end\n"
      definition = definition_for_facts
      %w[config/initializers/inflections.rb Gemfile.lock app/models/invoice.rb].each do |relative|
        graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
        document = document_for(graph)
        ArchSpec::Facts.write("#{root}/archspec_facts/custom.yml", document)
        write "#{root}/#{relative}", "# changed\n"
        assert_equal ['facts.stale'], stale_diagnostics(definition, root).map(&:rule)
      end
    end
  end

  def test_invalid_sources_locations_types_and_yaml_cannot_supply_facts
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice; end\n"
      definition = definition_for_facts
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      good = { 'source' => 'Invoice', 'target' => 'Customer', 'path' => 'app/models/invoice.rb', 'line' => 1 }
      [good.merge('path' => '../outside.rb'), good.merge('path' => "#{root}/app/models/invoice.rb"),
       good.merge('line' => 200), good.merge('column' => 200), good.merge('source' => 'Missing'),
       good.merge('target' => nil), good.merge('extra' => 'typo'), 'not a fact'].each do |entry|
        document = document_for(graph).merge('references' => [entry])
        ArchSpec::Facts.write("#{root}/archspec_facts/custom.yml", document)
        assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(definition, root: root) }
      end
      write "#{root}/archspec_facts/custom.yml", "--- !ruby/object:Object {}\n"
      assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(definition, root: root) }
      ArchSpec::Facts.write("#{root}/archspec_facts/custom.yml", document_for(graph).merge('version' => 99))
      assert_raises(ArchSpec::Error) { ArchSpec::Analyzer.analyze(definition, root: root) }
    end
  end

  def test_configured_facts_inside_config_do_not_invalidate_themselves
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice; end\n"
      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        facts 'config/archspec_facts'
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root, include_facts: false)
      document = document_for(graph).merge('snapshot' => ArchSpec::Facts.snapshot(graph, excluding: definition.facts_path))
      ArchSpec::Facts.write("#{root}/config/archspec_facts/custom.yml", document)
      assert_equal graph.files.keys, ArchSpec::Analyzer.analyze(definition, root: root).files.keys
    end
  end

  def test_check_and_explain_consume_facts_without_loading_application_code
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\nfacts 'archspec_facts'\n"
      write "#{root}/app/models/invoice.rb", "raise 'application must not boot'\nclass Invoice; end\n"
      write "#{root}/config/environment.rb", "raise 'Rails must not boot'\n"
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      ArchSpec::Facts.write("#{root}/archspec_facts/custom.yml", document_for(graph))
      %w[check explain].each do |command|
        argv = [command, '--config', "#{root}/Archspec.rb"]
        argv << 'Invoice' if command == 'explain'
        error = StringIO.new
        assert_equal 0, ArchSpec::CLI.run(argv, output: StringIO.new, error: error), error.string
      end
    end
  end

  private

  def stale_diagnostics(definition, root)
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    ArchSpec::Evaluator.evaluate(definition, graph).select { |diagnostic| diagnostic.rule == 'facts.stale' }
  end

  def definition_for_facts
    ArchSpec.define do
      component :invoices, constants: 'Invoice'
      component :customers, constants: 'Customer'
      invoices.cannot_use :customers
      invoices.must_implement :customer
      facts 'archspec_facts'
    end
  end

  def document_for(graph)
    { 'version' => 1, 'producer' => 'custom', 'snapshot' => ArchSpec::Facts.snapshot(graph),
      'references' => [], 'methods' => [], 'gaps' => [] }
  end
end
