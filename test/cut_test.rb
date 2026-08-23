# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'

class CutTest < ArchSpecTest
  def test_a_privacy_breach_points_at_the_public_face_that_already_reaches_the_private_constant
    with_project do |root|
      write "#{root}/packs/billing/app/public/billing/invoicer.rb", <<~RUBY
        module Billing
          class Invoicer
            Ledger
          end
        end
      RUBY
      write "#{root}/packs/billing/app/models/billing/ledger.rb", "module Billing\n  class Ledger; end\nend\n"
      write "#{root}/app/controllers/orders_controller.rb", "class OrdersController\n  Billing::Ledger\nend\n"

      definition = ArchSpec.define do
        source 'app/**/*.rb', 'packs/*/app/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        component :billing, in: 'packs/billing/**/*.rb'
        billing.public_api 'packs/billing/app/public/**/*.rb'
      end

      diagnostic = diagnostics_for(definition, root).first

      assert_equal 'dependencies.privacy', diagnostic.rule
      assert_equal 'reference Billing::Invoicer instead, the public face of billing that already reaches Billing::Ledger',
                   diagnostic.suggested_action
      assert_match(/action: reference Billing::Invoicer instead/, check_output(definition, root))
    end
  end

  def test_a_forbidden_dependency_with_no_public_face_to_point_at_admits_it
    with_project do |root|
      write "#{root}/app/models/report.rb", <<~RUBY
        class Report
          ReportsController
          Mailer
          Formatter
        end
      RUBY
      write "#{root}/app/controllers/reports_controller.rb", "class ReportsController; end\n"
      write "#{root}/app/services/mailer.rb", "class Mailer; end\n"
      write "#{root}/app/services/formatter.rb", "class Formatter; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        component :services, in: 'app/services/**/*.rb'
        models.cannot_use :controllers
      end

      diagnostic = diagnostics_for(definition, root).first

      assert_equal ArchSpec::Cut::NONE, diagnostic.suggested_action
    end
  end

  def test_a_breach_with_no_cut_in_the_graph_says_so
    with_project do |root|
      write_models_and_controllers(root)

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers
      end

      diagnostic = diagnostics_for(definition, root).first

      assert_equal 'no cut the graph can see', diagnostic.suggested_action
      assert_match(/action: no cut the graph can see/, check_output(definition, root))
    end
  end

  def test_a_cycle_points_at_its_lightest_edge
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  UsersController\n  UsersHelper\nend\n"
      write "#{root}/app/models/account.rb", "class Account\n  UsersController\nend\n"
      write "#{root}/app/controllers/users_controller.rb", "class UsersController\n  User\nend\n"
      write "#{root}/app/helpers/users_helper.rb", "class UsersHelper; end\n"

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        component :helpers, in: 'app/helpers/**/*.rb'
        no_cycles
      end

      diagnostic = diagnostics_for(definition, root).first

      assert_equal 'dependencies.no_cycles', diagnostic.rule
      assert_equal 'break controllers -> models, the edge of this cycle with the fewest dependencies behind it (1)',
                   diagnostic.suggested_action
    end
  end

  def test_a_concern_breach_names_what_to_move_out_of_the_concern
    with_project do |root|
      write "#{root}/app/models/concerns/chargeable.rb", "module Chargeable\n  def charge\n    Order.create!\n  end\nend\n"
      write "#{root}/app/models/order.rb", "class Order\n  include Chargeable\nend\n"

      definition = ArchSpec.define do
        component :concerns, in: 'app/models/concerns/**/*.rb'
        concerns.cannot_reference_includers
      end

      diagnostic = diagnostics_for(definition, root).first

      assert_equal 'move what reaches Order out of Chargeable; Order owns it', diagnostic.suggested_action
    end
  end

  def test_json_carries_reason_since_and_action
    with_project do |root|
      write_models_and_controllers(root)

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :controllers, in: 'app/controllers/**/*.rb'
        models.cannot_use :controllers, because: 'why', since: '2024-01-01'
      end

      violation = JSON.parse(json_output(definition, root))['violations'].first

      assert_equal 'why', violation['reason']
      assert_equal '2024-01-01', violation['since']
      assert_equal 'unknown', violation['age']
      assert_equal 'no cut the graph can see', violation['suggested_action']
    end
  end

  private

  def write_models_and_controllers(root)
    write "#{root}/app/models/user.rb", "class User\n  UsersController\nend\n"
    write "#{root}/app/controllers/users_controller.rb", "class UsersController; end\n"
  end

  def check_output(definition, root)
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
    output = StringIO.new
    ArchSpec::Formatters::Text.print(output, graph: graph, diagnostics: diagnostics)
    output.string
  end

  def json_output(definition, root)
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    diagnostics = ArchSpec::Evaluator.evaluate(definition, graph)
    output = StringIO.new
    ArchSpec::Formatters::JSON.print(output, graph: graph, diagnostics: diagnostics)
    output.string
  end

end
