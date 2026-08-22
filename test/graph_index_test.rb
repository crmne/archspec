# frozen_string_literal: true

require 'test_helper'

class GraphIndexTest < ArchSpecTest
  def test_remembered_ancestry_walks_hand_out_independent_copies
    with_project do |root|
      write "#{root}/app/models/base.rb", "class Base\n  def save; end\nend\n"
      write "#{root}/app/models/user.rb", "class User < Base\n  def name; end\nend\n"
      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      first, = graph.effective_instance_methods('User')
      first << :tampered
      second, unresolved = graph.effective_instance_methods('User')

      assert_equal Set[:name, :save], second
      assert_empty unresolved
    end
  end

  def test_the_memo_and_the_indexes_are_dropped_when_the_graph_grows
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User\n  def name; end\nend\n"
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      assert_equal Set[:name], graph.effective_instance_methods('User').first
      assert_equal Set[:models], graph.component_names_for_path("#{root}/app/models/user.rb")

      graph.constants_named('User').first.add_instance_method(:email, location: graph.constants.first.location)
      graph.add_edge(type: :references_constant, from_path: "#{root}/app/models/user.rb", from_constant: 'User',
                     to: 'Account', location: graph.constants.first.location)

      assert_equal Set[:name, :email], graph.effective_instance_methods('User').first
      assert_equal 1, graph.dependency_edges.size
    end
  end

  def test_component_queries_answer_from_the_indexes_as_the_scan_did
    with_project do |root|
      write "#{root}/app/models/user.rb", "class User; end\nclass Billing::Invoice; end\n"
      graph = ArchSpec::Analyzer.analyze(ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :billing, namespace: 'Billing'
      end, root: root)

      assert_equal Set[:models, :billing], graph.component_names_for_constant('Billing::Invoice')
      assert_equal Set[:models, :billing],
                   graph.component_names_for_constant('Billing::Invoice', path: "#{root}/app/models/user.rb")
      assert_equal Set[], graph.component_names_for_constant('Billing::Invoice', path: "#{root}/elsewhere.rb")
      assert_equal %w[Billing::Invoice], graph.constants_for_component(:billing).map(&:name)
      assert_equal [], graph.constants_for_component(:missing)
      assert_equal [], graph.method_definitions_for_component(:missing)
    end
  end

  private

  def definition
    ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
  end
end
