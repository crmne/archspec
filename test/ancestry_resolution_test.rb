# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'stringio'

class AncestryResolutionTest < ArchSpecTest
  def test_a_constant_defined_on_the_superclass_resolves_through_ancestry
    with_project do |root|
      write "#{root}/app/base/base.rb", "class Base; class Settings; end; end\n"
      write "#{root}/app/models/user.rb", "class User < Base\n  Settings\nend\n"

      graph = graph_for(layered_definition, root)
      edge = reference_from(graph, 'User', 'Settings')

      resolution = graph.resolve_edge(edge)
      assert_equal 'Base::Settings', resolution.name
      assert_equal :ancestry, resolution.determination
      assert_equal 'Base', resolution.ancestor
      assert_equal %w[Base Settings], diagnostics_for(layered_definition, root).map(&:evidence).map { |e| e.split.last }.sort
    end
  end

  def test_a_constant_defined_on_an_included_module_resolves_through_ancestry
    with_project do |root|
      write "#{root}/app/base/billable.rb", "module Billable; class Plan; end; end\n"
      write "#{root}/app/models/user.rb", "class User\n  include Billable\n  Plan\nend\n"

      graph = graph_for(layered_definition, root)

      assert_equal 'Billable::Plan', graph.resolve_edge(reference_from(graph, 'User', 'Plan')).name
    end
  end

  def test_a_prepended_module_is_walked_before_the_superclass
    with_project do |root|
      write "#{root}/app/base/base.rb", "class Base; class Plan; end; end\n"
      write "#{root}/app/base/early.rb", "module Early; class Plan; end; end\n"
      write "#{root}/app/models/user.rb", "class User < Base\n  prepend Early\n  Plan\nend\n"

      graph = graph_for(layered_definition, root)
      resolution = graph.resolve_edge(reference_from(graph, 'User', 'Plan'))

      assert_equal :unresolved, resolution.determination
      assert_equal :ambiguous, resolution.cause
    end
  end

  def test_ancestors_at_different_depths_take_the_nearest
    with_project do |root|
      write "#{root}/app/base/root.rb", "class Root; class Plan; end; end\n"
      write "#{root}/app/base/base.rb", "class Base < Root; class Plan; end; end\n"
      write "#{root}/app/models/user.rb", "class User < Base\n  Plan\nend\n"

      graph = graph_for(layered_definition, root)
      resolution = graph.resolve_edge(reference_from(graph, 'User', 'Plan'))

      assert_equal 'Base::Plan', resolution.name
      assert_equal 'Base', resolution.ancestor
    end
  end

  def test_the_qualified_form_walks_the_prefix_ancestry
    with_project do |root|
      write "#{root}/app/base/base.rb", "class Base; class Settings; end; end\n"
      write "#{root}/app/base/user.rb", "class User < Base; end\n"
      write "#{root}/app/models/report.rb", "class Report\n  User::Settings\nend\n"

      graph = graph_for(layered_definition, root)
      resolution = graph.resolve_edge(reference_from(graph, 'Report', 'User::Settings'))

      assert_equal 'Base::Settings', resolution.name
      assert_equal :ancestry, resolution.determination
      assert_equal 'Base', resolution.ancestor
    end
  end

  def test_an_unresolved_ancestor_stops_the_walk
    with_project do |root|
      write "#{root}/app/base/base.rb", "class Base; class Settings; end; end\n"
      write "#{root}/app/models/user.rb", "class User < SomeGem::Record\n  Settings\nend\n"

      graph = graph_for(layered_definition, root)
      resolution = graph.resolve_edge(reference_from(graph, 'User', 'Settings'))

      assert_equal :unresolved, resolution.determination
      assert_equal :ancestor_unresolved, resolution.cause
      assert_equal 'SomeGem::Record', resolution.ancestor
      assert_equal 'Settings', resolution.name
      assert_empty diagnostics_for(layered_definition, root)
    end
  end

  def test_an_unresolved_ancestor_refuses_even_when_a_nearer_sibling_would_answer
    with_project do |root|
      write "#{root}/app/base/billable.rb", "module Billable; class Settings; end; end\n"
      write "#{root}/app/models/user.rb", "class User < SomeGem::Record\n  include Billable\n  Settings\nend\n"

      graph = graph_for(layered_definition, root)

      assert_equal :ancestor_unresolved, graph.resolve_edge(reference_from(graph, 'User', 'Settings')).cause
    end
  end

  def test_the_walk_stops_at_object_and_survives_cycles
    with_project do |root|
      write "#{root}/app/base/a.rb", "module A; include B; end\n"
      write "#{root}/app/base/b.rb", "module B; include A; end\n"
      write "#{root}/app/models/user.rb", "class User < Object\n  include A\n  Missing\nend\n"

      graph = graph_for(layered_definition, root)
      resolution = graph.resolve_edge(reference_from(graph, 'User', 'Missing'))

      assert_equal :unresolved, resolution.determination
      assert_equal :undefined, resolution.cause
    end
  end

  def test_resolutions_are_remembered_until_the_graph_changes
    with_project do |root|
      write "#{root}/app/base/base.rb", "class Base; class Settings; end; end\n"
      write "#{root}/app/models/user.rb", "class User < Base\n  Settings\nend\n"

      graph = graph_for(layered_definition, root)
      edge = reference_from(graph, 'User', 'Settings')
      assert_equal 'Base::Settings', graph.resolve_edge(edge).name

      location = ArchSpec::SourceLocation.new("#{root}/app/models/user.rb", 1, 1, 1, 1)
      graph.add_constant(name: 'User::Settings', kind: :class, path: "#{root}/app/models/user.rb", location: location)

      assert_equal 'User::Settings', graph.resolve_edge(edge).name
      assert_equal :lexical, graph.resolve_edge(edge).determination
    end
  end

  def test_a_lexical_resolution_keeps_its_message_and_evidence
    with_project do |root|
      write "#{root}/app/base/settings.rb", "class Settings; end\n"
      write "#{root}/app/models/user.rb", "class User\n  Settings\nend\n"

      diagnostic = diagnostics_for(layered_definition, root).first

      assert_equal 'models must not depend on base', diagnostic.message
      assert_equal 'User references Settings', diagnostic.evidence
      graph = graph_for(layered_definition, root)
      assert_equal :lexical, graph.resolve_edge(reference_from(graph, 'User', 'Settings')).determination
    end
  end

  def test_the_census_counts_ancestry_resolutions_and_refusals
    with_project do |root|
      write "#{root}/app/base/base.rb", "class Base; class Settings; end; class Plan; end; end\n"
      write "#{root}/app/base/early.rb", "module Early; class Plan; end; end\n"
      write "#{root}/app/models/user.rb", "class User < Base\n  prepend Early\n  Settings\n  Plan\nend\n"
      write "#{root}/app/models/guest.rb", "class Guest < SomeGem::Record\n  Settings\nend\n"

      output = StringIO.new
      ArchSpec::CLI.run(['check', '--config', write_config(root), '--format', 'json'], output: output, error: StringIO.new)
      census = JSON.parse(output.string).fetch('census').fetch('references')

      assert_equal 1, census['through_ancestry']
      assert_equal 1, census.dig('refused', 'ancestor_unresolved')
      assert_equal 1, census.dig('refused', 'ambiguous')
      assert_equal %w[Plan Settings], census.dig('refused', 'names')

      text = StringIO.new
      ArchSpec::CLI.run(['check', '--config', write_config(root)], output: text, error: StringIO.new)
      assert_match(/could not see: .*1 reference refused at an unresolved ancestor, 1 ambiguous ancestry reference/, text.string)
    end
  end

  def test_explain_names_the_ancestor_a_reference_resolved_through
    with_project do |root|
      write "#{root}/app/base/base.rb", "class Base; class Settings; end; end\n"
      write "#{root}/app/models/user.rb", "class User < Base\n  Settings\nend\n"

      output = StringIO.new
      ArchSpec::CLI.run(['explain', 'app/models/user.rb', '--config', write_config(root)], output: output, error: StringIO.new)

      assert_match(/references Settings \(Base::Settings via Base\)/, output.string)
    end
  end

  private

  def layered_definition
    ArchSpec.define do
      source 'app/**/*.rb'
      component :base, in: 'app/base/**/*.rb'
      component :models, in: 'app/models/**/*.rb'
      models.cannot_use :base
    end
  end

  def write_config(root)
    path = "#{root}/Archspec.rb"
    write path, <<~RUBY
      source 'app/**/*.rb'
      component :base, in: 'app/base/**/*.rb'
      component :models, in: 'app/models/**/*.rb'
      models.cannot_use :base
    RUBY
    path
  end

  def graph_for(definition, root)
    ArchSpec::Analyzer.analyze(definition, root: root)
  end

  def reference_from(graph, constant, target = nil)
    graph.edges.find do |edge|
      edge.type == :references_constant && edge.from_constant == constant && (target.nil? || edge.to == target)
    end
  end
end
