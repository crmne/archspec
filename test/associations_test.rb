# frozen_string_literal: true

require 'test_helper'
require 'stringio'

class AssociationsTest < ArchSpecTest
  def test_a_literal_class_name_is_a_declared_edge
    facts = facts_for(
      'app/models/post.rb' => "class Post < ApplicationRecord\n  belongs_to :writer, class_name: 'User'\nend\n",
      'app/models/user.rb' => "class User < ApplicationRecord; end\n"
    )

    assert_equal [%w[Post User declared belongs_to writer]], rows(facts)
    assert_empty facts[:misses]
  end

  def test_a_literal_class_name_resolves_in_the_owners_namespace_first
    facts = facts_for(
      'app/models/billing/invoice.rb' => "module Billing\n  class Invoice < ApplicationRecord\n    belongs_to :buyer, class_name: 'Account'\n  end\nend\n",
      'app/models/billing/account.rb' => "module Billing\n  class Account < ApplicationRecord; end\nend\n",
      'app/models/account.rb' => "class Account < ApplicationRecord; end\n"
    )

    assert_equal [['Billing::Invoice', 'Billing::Account', 'declared', 'belongs_to', 'buyer']], rows(facts)
  end

  def test_a_bare_singular_name_resolves_against_the_declared_models
    facts = facts_for(
      'app/models/post.rb' => "class Post < ApplicationRecord\n  belongs_to :user\nend\n",
      'app/models/user.rb' => "class User < ApplicationRecord; end\n"
    )

    assert_equal [%w[Post User index belongs_to user]], rows(facts)
  end

  def test_a_bare_collection_name_resolves_by_the_three_spellings_only
    facts = facts_for(
      'app/models/user.rb' => "class User < ApplicationRecord\n  has_many :posts\n  has_many :addresses\n  has_many :companies\n  has_many :people\nend\n",
      'app/models/post.rb' => "class Post < ApplicationRecord; end\n",
      'app/models/address.rb' => "class Address < ApplicationRecord; end\n",
      'app/models/company.rb' => "class Company < ApplicationRecord; end\n",
      'app/models/person.rb' => "class Person < ApplicationRecord; end\n"
    )

    assert_equal %w[Address Company Post], rows(facts).map { |row| row[1] }
    assert_equal %w[index index index], rows(facts).map { |row| row[2] }
    assert_equal({ 'unresolved' => 1 }, facts[:misses])
  end

  def test_the_enclosing_namespace_wins_over_the_top_level
    facts = facts_for(
      'app/models/billing/invoice.rb' => "module Billing\n  class Invoice < ApplicationRecord\n    belongs_to :account\n  end\nend\n",
      'app/models/billing/account.rb' => "module Billing\n  class Account < ApplicationRecord; end\nend\n",
      'app/models/account.rb' => "class Account < ApplicationRecord; end\n"
    )

    assert_equal [['Billing::Invoice', 'Billing::Account', 'index', 'belongs_to', 'account']], rows(facts)
  end

  def test_sti_subclasses_enter_the_index
    facts = facts_for(
      'app/models/user.rb' => "class User < ApplicationRecord; end\n",
      'app/models/admin.rb' => "class Admin < User; end\n",
      'app/models/audit.rb' => "class Audit < ApplicationRecord\n  belongs_to :admin\nend\n"
    )

    assert_equal [%w[Audit Admin index belongs_to admin]], rows(facts)
  end

  def test_through_walks_one_hop_into_the_intermediates_own_declaration
    facts = facts_for(
      'app/models/post.rb' => "class Post < ApplicationRecord\n  has_many :taggings\n  has_many :tags, through: :taggings\n  has_many :labels, through: :taggings, source: :tag\nend\n",
      'app/models/tagging.rb' => "class Tagging < ApplicationRecord\n  belongs_to :tag\nend\n",
      'app/models/tag.rb' => "class Tag < ApplicationRecord; end\n"
    )

    assert_equal [%w[Post Tag through has_many labels], %w[Post Tag through has_many tags],
                  %w[Post Tagging index has_many taggings], %w[Tagging Tag index belongs_to tag]], rows(facts)
  end

  def test_polymorphic_and_source_type_are_counted_not_guessed
    facts = facts_for(
      'app/models/comment.rb' => "class Comment < ApplicationRecord\n  belongs_to :commentable, polymorphic: true\n  has_many :taggings\n  has_many :tags, through: :taggings, source: :taggable, source_type: 'Tag'\nend\n",
      'app/models/tagging.rb' => "class Tagging < ApplicationRecord; end\n"
    )

    assert_equal [%w[Comment Tagging index has_many taggings]], rows(facts)
    assert_equal({ 'polymorphic' => 1, 'source_type' => 1 }, facts[:misses])
  end

  def test_an_ambiguous_name_is_a_miss
    facts = facts_for(
      'app/models/user.rb' => "class User < ApplicationRecord\n  has_many :buses\nend\n",
      'app/models/bus.rb' => "class Bus < ApplicationRecord; end\n",
      'app/models/buse.rb' => "class Buse < ApplicationRecord; end\n"
    )

    assert_empty rows(facts)
    assert_equal({ 'ambiguous' => 1 }, facts[:misses])
  end

  def test_a_non_literal_class_name_is_a_miss
    facts = facts_for(
      'app/models/post.rb' => "class Post < ApplicationRecord\n  belongs_to :writer, class_name: writer_class\nend\n"
    )

    assert_empty rows(facts)
    assert_equal({ 'dynamic' => 1 }, facts[:misses])
  end

  def test_an_unresolved_through_is_a_miss
    facts = facts_for(
      'app/models/post.rb' => "class Post < ApplicationRecord\n  has_many :tags, through: :taggings\n  has_many :votes, through: :voters\n  has_many :voters\nend\n",
      'app/models/voter.rb' => "class Voter < ApplicationRecord\n  has_many :votes, through: :ballots\nend\n"
    )

    assert_equal [%w[Post Voter index has_many voters]], rows(facts)
    assert_equal({ 'unresolved_through' => 3 }, facts[:misses])
  end

  def test_concerns_and_abstract_classes_own_nothing
    facts = facts_for(
      'app/models/concerns/taggable.rb' => "module Taggable\n  extend ActiveSupport::Concern\n  included do\n    has_many :tags\n  end\nend\n",
      'app/models/base.rb' => "class Base < ApplicationRecord\n  self.abstract_class = true\n  belongs_to :tenant\nend\n",
      'app/models/tag.rb' => "class Tag < ApplicationRecord; end\n",
      'app/models/tenant.rb' => "class Tenant < ApplicationRecord; end\n"
    )

    assert_empty rows(facts)
    assert_equal({ 'unowned' => 2 }, facts[:misses])
  end

  def test_a_subclass_restating_an_inherited_association_is_a_miss
    facts = facts_for(
      'app/models/post.rb' => "class Post < ApplicationRecord\n  belongs_to :user\nend\n",
      'app/models/guest_post.rb' => "class GuestPost < Post\n  belongs_to :user\nend\n",
      'app/models/user.rb' => "class User < ApplicationRecord; end\n"
    )

    assert_equal [%w[Post User index belongs_to user]], rows(facts)
    assert_equal({ 'restated' => 1 }, facts[:misses])
  end

  def test_built_in_associations_make_the_dependency_visible_to_rules
    with_project do |root|
      write_models(root)

      definition = ArchSpec.define do
        facts 'archspec_facts', associations: :static
        component :models, in: 'app/models/**/*.rb'
        component :sessions, in: 'app/models/session.rb'
        models.cannot_use :sessions
      end

      diagnostics = diagnostics_for(definition, root)

      assert_equal 1, diagnostics.size
      assert_equal 'User references Session (from archspec-associations (built in))', diagnostics.first.evidence
      assert_equal :from_facts_file, diagnostics.first.confidence
    end
  end

  def test_without_the_option_the_association_stays_invisible
    with_project do |root|
      write_models(root)

      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :sessions, in: 'app/models/session.rb'
        models.cannot_use :sessions
      end

      assert_empty diagnostics_for(definition, root)
    end
  end

  def test_the_option_accepts_only_static
    error = assert_raises(ArchSpec::Error) do
      ArchSpec.define { facts 'archspec_facts', associations: :runtime }
    end

    assert_match 'associations: must be :static', error.message
  end

  def test_reflect_static_writes_the_file_without_booting
    with_project do |root|
      write_models(root)
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"

      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['reflect', '--static'], output: output, error: StringIO.new) }

      assert_equal 0, status
      assert_equal ['Wrote archspec_facts/associations.yml', '1 reference, no misses'], output.string.lines.map(&:strip)
      loaded = ArchSpec::Facts.load("#{root}/archspec_facts", root: root)
      assert_equal 'archspec-associations', loaded.files.first.producer
      assert_equal ['Session'], loaded.references.map(&:target)
      assert_equal ['index'], loaded.references.map(&:determination)
    end
  end

  def test_check_reports_the_built_in_producer_beside_the_files
    with_project do |root|
      write_models(root)
      write "#{root}/Archspec.rb", <<~RUBY
        facts 'archspec_facts', associations: :static
        component :models, in: 'app/models/**/*.rb'
      RUBY

      output = StringIO.new
      Dir.chdir(root) { ArchSpec::CLI.run(['check'], output: output, error: StringIO.new) }

      assert_match "facts: archspec-associations (built in) (archspec-associations #{ArchSpec::VERSION}, 1 entry)", output.string
    end
  end

  private

  def facts_for(files)
    with_project do |root|
      files.each { |path, source| write "#{root}/#{path}", source }
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      ArchSpec::Associations.facts_for(graph)
    end
  end

  def rows(facts)
    facts[:references].map { |reference| [reference.owner, reference.target, reference.determination, reference.macro, reference.name] }
                      .sort
  end

  def write_models(root)
    write "#{root}/app/models/user.rb", "class User < ApplicationRecord\n  belongs_to :session\nend\n"
    write "#{root}/app/models/session.rb", "class Session < ApplicationRecord; end\n"
  end
end
