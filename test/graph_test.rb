# frozen_string_literal: true

require 'test_helper'

class GraphTest < ArchSpecTest
  def test_component_lookups_follow_component_reassignment
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice; end\n"
      write "#{root}/app/mailers/invoice_mailer.rb", <<~RUBY
        Invoice

        class InvoiceMailer
          def invoice_class = Invoice
        end
      RUBY
      graph = analyze(root) do
        component :models, in: 'app/models/**/*.rb'
        component :mailers, in: 'app/mailers/**/*.rb'
      end
      edge = reference(graph, 'Invoice', from: 'InvoiceMailer')
      top_level = reference(graph, 'Invoice', from: nil)

      assert_equal [:mailers], graph.source_components_for(edge).to_a
      assert_equal [:models], graph.target_components_for(edge).to_a
      assert_equal [:mailers], graph.source_components_for(top_level).to_a
      assert_equal [:models], graph.component_names_for_path("#{root}/app/models/invoice.rb").to_a

      graph.assign_components(specs { component :billing, constants: %w[Invoice InvoiceMailer] })

      assert_equal [:billing], graph.source_components_for(edge).to_a
      assert_equal [:billing], graph.target_components_for(edge).to_a
      assert_equal [:billing], graph.source_components_for(top_level).to_a
      assert_equal [:billing], graph.component_names_for_path("#{root}/app/models/invoice.rb").to_a
    end
  end

  def test_edge_resolution_sees_a_constant_added_later
    with_project do |root|
      path = "#{root}/app/models/billing/invoice.rb"
      write path, <<~RUBY
        module Billing
          class Invoice
            def total = Money
          end
        end
      RUBY
      graph = analyze(root) { component :billing, namespace: 'Billing' }
      edge = reference(graph, 'Money', from: 'Billing::Invoice')

      assert_equal 'Money', graph.resolve_edge_constant(edge)
      assert_empty graph.target_components_for(edge)

      graph.add_constant(name: 'Billing::Money', kind: :class, path: path, location: edge.location)

      assert_equal 'Billing::Money', graph.resolve_edge_constant(edge)
      assert_empty graph.target_components_for(edge)

      graph.assign_components(specs { component :billing, namespace: 'Billing' })

      assert_equal [:billing], graph.target_components_for(edge).to_a
    end
  end

  def test_component_names_for_constant_tells_occurrences_apart
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice; end\n"
      write "#{root}/lib/invoice.rb", "class Invoice; end\n"
      graph = analyze(root) do
        component :models, in: 'app/**/*.rb'
        component :library, in: 'lib/**/*.rb'
      end

      assert_equal %i[library models], graph.component_names_for_constant('::Invoice').to_a.sort
      assert_equal [:models], graph.component_names_for_constant('Invoice', path: "#{root}/app/models/invoice.rb").to_a
      assert_equal [:library], graph.component_names_for_constant('Invoice', path: "#{root}/lib/invoice.rb").to_a
      assert_empty graph.component_names_for_constant('Receipt')
    end
  end

  def test_component_sets_are_shared_and_frozen
    with_project do |root|
      write "#{root}/app/models/invoice.rb", <<~RUBY
        class Invoice
          def self.blank = Invoice
        end
      RUBY
      graph = analyze(root) { component :models, in: 'app/**/*.rb' }
      edge = reference(graph, 'Invoice', from: 'Invoice')

      assert_same graph.target_components_for(edge), graph.target_components_for(edge)
      assert_raises(FrozenError) { graph.source_components_for(edge) << :mailers }
    end
  end

  private

  def analyze(root, &declarations)
    ArchSpec::Analyzer.analyze(ArchSpec.define(&declarations), root: root)
  end

  def specs(&declarations)
    ArchSpec.define(&declarations).component_specs.values
  end

  def reference(graph, name, from:)
    graph.edges.find do |edge|
      edge.type == :references_constant && edge.to == name && edge.from_constant == from
    end
  end
end
