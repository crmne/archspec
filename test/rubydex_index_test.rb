# frozen_string_literal: true

require 'test_helper'

class RubydexIndexTest < ArchSpecTest
  def test_resolves_references_through_constant_aliases
    with_project do |root|
      write "#{root}/app/payments.rb", <<~RUBY
        module Payments
          class Invoice
          end
        end

        Billing = Payments

        class Report
          def invoice_class = Billing::Invoice
        end
      RUBY

      graph = analyze(root)
      reference = graph.edges.find do |edge|
        edge.type == :references_constant && edge.to == 'Billing::Invoice'
      end

      assert_equal 'Payments::Invoice', reference.resolved_to
      assert_equal 'Payments::Invoice', graph.resolve_edge_constant(reference)
    end
  end

  def test_resolves_references_through_inherited_constants
    with_project do |root|
      write "#{root}/app/report.rb", <<~RUBY
        module ReportDefaults
          FORMAT = :html
        end

        class BaseReport
          include ReportDefaults
        end

        class SalesReport < BaseReport
          def format = FORMAT
        end
      RUBY

      graph = analyze(root)
      reference = graph.edges.find do |edge|
        edge.type == :references_constant && edge.from_constant == 'SalesReport' && edge.to == 'FORMAT'
      end

      assert_equal 'ReportDefaults::FORMAT', reference.resolved_to
      assert_equal 'ReportDefaults::FORMAT', graph.resolve_edge_constant(reference)
    end
  end

  def test_indexes_method_visibility_and_generated_accessors
    with_project do |root|
      write "#{root}/app/report.rb", <<~RUBY
        class Report
          private
          attr_accessor :title
        end
      RUBY

      graph = analyze(root)
      definitions = graph.constants_named('Report').first.method_definitions

      assert_equal %i[title title=], definitions.map(&:name)
      assert definitions.all? { |definition| definition.visibility == :private }
    end
  end

  def test_indexes_method_signatures
    with_project do |root|
      write "#{root}/app/charge.rb", <<~RUBY
        class Charge
          def call(amount, currency = :eur, actor:, trace: false, **options, &block) = amount
        end
      RUBY

      graph = analyze(root)
      definition = graph.constants_named('Charge').first.method_definitions.find { |method| method.name == :call }
      signature = definition.signatures.first

      assert_equal 1, signature.required
      assert_equal 1, signature.optional
      assert_equal %i[actor], signature.keywords
      assert_equal %i[trace], signature.optional_keywords
      assert signature.keyword_rest
      assert signature.block
    end
  end

  def test_fills_constant_assignment_shapes_rubydex_does_not_index
    with_project do |root|
      write "#{root}/app/settings.rb", <<~RUBY
        class Settings
          MODES = %w[automatic manual].freeze
        end
      RUBY

      graph = analyze(root)
      constant = graph.constants_named('Settings::MODES').first

      assert_equal :constant, constant.kind
    end
  end

  private

  def analyze(root)
    definition = ArchSpec.define { component :app, in: 'app/**/*.rb' }
    ArchSpec::Analyzer.analyze(definition, root: root)
  end
end
