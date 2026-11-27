# frozen_string_literal: true

require 'test_helper'

class GraphTest < ArchSpecTest
  def test_ancestor_names_follow_a_mixin_fact_applied_later
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice; end\n"
      write "#{root}/app/models/auditable.rb", "module Auditable; end\n"
      graph = analyze(root) { component :models, in: 'app/**/*.rb' }
      invoice = graph.constants_named('Invoice').first

      assert_empty graph.ancestor_names('Invoice').first

      facts = ArchSpec::Facts::Builder.new(graph, producer: 'test')
      facts.mixin(owner: invoice, target: 'Auditable', kind: :include, location: invoice.location)
      facts.apply

      assert_equal ['Auditable'], graph.ancestor_names('Invoice').first.to_a
      assert_empty graph.ancestor_names('Invoice', scope: :class).first
    end
  end

  def test_ancestor_names_follow_a_constant_added_later
    with_project do |root|
      path = "#{root}/app/models/invoice.rb"
      write path, "class Invoice < Record; end\n"
      graph = analyze(root) { component :models, in: 'app/**/*.rb' }
      invoice = graph.constants_named('Invoice').first

      assert_equal [Set['Record'], Set['Record']], graph.ancestor_names('Invoice')

      graph.add_constant(name: 'Record', kind: :class, path: path, location: invoice.location)

      assert_equal [Set['Record'], Set[]], graph.ancestor_names('Invoice')
    end
  end

  def test_ancestor_names_in_a_cycle_do_not_depend_on_which_module_was_asked_first
    with_project do |root|
      write "#{root}/app/models/auditable.rb", "module Auditable; include Trackable; end\n"
      write "#{root}/app/models/trackable.rb", "module Trackable; include Auditable; end\n"
      graph = analyze(root) { component :models, in: 'app/**/*.rb' }

      assert_equal %w[Auditable Trackable], graph.ancestor_names('Auditable').first.to_a.sort
      assert_equal %w[Auditable Trackable], graph.ancestor_names('Trackable').first.to_a.sort
      assert_equal %w[Auditable Trackable], graph.ancestor_names('Auditable').first.to_a.sort
    end
  end

  def test_ancestor_names_are_shared_and_frozen
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice < Record; end\n"
      graph = analyze(root) { component :models, in: 'app/**/*.rb' }

      assert_same graph.ancestor_names('Invoice'), graph.ancestor_names('::Invoice')
      assert_raises(FrozenError) { graph.ancestor_names('Invoice').first << 'Auditable' }
    end
  end

  def test_a_file_name_without_glob_characters_selects_that_file
    with_project do |root|
      write "#{root}/app/models/invoice.rb", "class Invoice; end\n"
      write "#{root}/app/models/receipt.rb", "class Receipt; end\n"
      graph = analyze(root) do
        component :invoices, in: 'app/models/invoice.rb'
        component :receipts, in: 'app/models/../models/receipt.rb'
        component :drafts, in: 'app/models/draft.rb'
        component :models, in: 'app/models/*.rb', except: 'app/models/receipt.rb'
      end

      assert_equal ["#{root}/app/models/invoice.rb"], graph.components[:invoices].files.to_a
      assert_equal ["#{root}/app/models/receipt.rb"], graph.components[:receipts].files.to_a
      assert_empty graph.components[:drafts].files
      assert_equal ["#{root}/app/models/invoice.rb"], graph.components[:models].files.to_a
    end
  end

  private

  def analyze(root, &declarations)
    ArchSpec::Analyzer.analyze(ArchSpec.define(&declarations), root: root)
  end
end
