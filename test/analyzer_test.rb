require "test_helper"

class AnalyzerTest < ArchSpecTest
  def test_builds_graph_from_direct_prism_parse
    with_project do |root|
      write "#{root}/app/models/user.rb", <<~RUBY
        class User < ApplicationRecord
          include Billable

          def call
            Billing::Invoice.new
          end
        end
      RUBY

      write "#{root}/app/models/billing/invoice.rb", <<~RUBY
        module Billing
          class Invoice
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :models, in: "app/models/**/*.rb"
      end

      graph = ArchSpec::Analyzer.new(definition, root: root).call

      assert_equal ["Billing", "Billing::Invoice", "User"], graph.constants.map(&:name).sort
      assert_equal ["User"], graph.constants_named("User").map(&:name)
      assert graph.edges.any? { |edge| edge.type == :inherits_from && edge.to == "ApplicationRecord" }
      assert graph.edges.any? { |edge| edge.type == :includes && edge.to == "Billable" }
      assert graph.edges.any? { |edge| edge.type == :references_constant && edge.to == "Billing::Invoice" }
      assert_equal [:models], graph.component_names_for_path("#{root}/app/models/user.rb").to_a
    end
  end

  def test_expected_constant_uses_rails_paths
    with_project do |root|
      write "#{root}/app/services/billing/create_invoice.rb", <<~RUBY
        module Billing
          class CreateInvoice
          end
        end
      RUBY

      definition = ArchSpec.define do
        component :services, in: "app/services/**/*.rb"
      end

      graph = ArchSpec::Analyzer.new(definition, root: root).call
      file = graph.files.fetch("#{root}/app/services/billing/create_invoice.rb")

      assert_equal "Billing::CreateInvoice", file.expected_constant
    end
  end
end
