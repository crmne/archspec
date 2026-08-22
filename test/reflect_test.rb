# frozen_string_literal: true

require 'test_helper'

class ReflectTest < ArchSpecTest
  class Reflection
    attr_reader :name, :macro, :active_record

    def initialize(name:, macro:, polymorphic:, active_record:, klass_name:)
      @name = name
      @macro = macro
      @polymorphic = polymorphic
      @active_record = active_record
      @klass_name = klass_name
    end

    def polymorphic?
      @polymorphic
    end

    def klass
      raise NameError, "uninitialized constant #{name}" unless @klass_name

      Struct.new(:name).new(@klass_name)
    end
  end

  class Model
    attr_reader :name, :reflections

    def initialize(name)
      @name = name
      @reflections = []
    end

    def reflect_on_all_associations
      reflections
    end

    def association(name, macro, target: nil, polymorphic: false, owner: self)
      reflections << Reflection.new(name: name, macro: macro, polymorphic: polymorphic,
                                    active_record: owner, klass_name: target)
      self
    end
  end

  def test_resolved_associations_become_references_and_generated_methods
    user = Model.new('User')
                .association(:session, :belongs_to, target: 'Session')
                .association(:posts, :has_many, target: 'Post')

    facts = ArchSpec::Reflect.facts_for([user], root: Dir.pwd)

    assert_equal 'archspec-reflect', facts[:producer]
    assert_equal ArchSpec::VERSION, facts[:producer_version]
    assert_equal %w[Post Session], facts[:references].map(&:target)
    assert_equal %w[has_many belongs_to], facts[:references].map(&:macro)
    assert_equal %w[posts session], facts[:references].map(&:name)
    assert_equal ['User'], facts[:references].map(&:owner).uniq
    assert_equal %w[posts posts= posts_ids posts_ids= session session= build_session create_session create_session!
                    reload_session], facts[:generated_methods].first.names
    assert_empty facts[:misses]
  end

  def test_polymorphic_and_failing_reflections_are_counted_not_guessed
    comment = Model.new('Comment')
                   .association(:commentable, :belongs_to, polymorphic: true)
                   .association(:ghost, :has_one)

    facts = ArchSpec::Reflect.facts_for([comment], root: Dir.pwd)

    assert_empty facts[:references]
    assert_equal({ 'polymorphic' => 1, 'unresolved' => 1 }, facts[:misses])
    assert_includes facts[:generated_methods].first.names, 'commentable'
  end

  def test_inherited_associations_are_written_once_on_their_declaring_model
    base = Model.new('Post').association(:author, :belongs_to, target: 'User')
    child = Model.new('GuestPost')
    child.reflections.concat(base.reflections)

    facts = ArchSpec::Reflect.facts_for([child, base], root: Dir.pwd)

    assert_equal ['Post'], facts[:references].map(&:owner)
    assert_equal ['Post'], facts[:generated_methods].map(&:owner)
  end

  def test_written_files_are_sorted_and_load_back_identically
    with_project do |root|
      user = Model.new('User').association(:session, :belongs_to, target: 'Session')
      post = Model.new('Post').association(:author, :belongs_to, target: 'User')
      path = "#{root}/archspec_facts/rails.yml"
      FileUtils.mkdir_p(File.dirname(path))

      facts = ArchSpec::Reflect.facts_for([user, post], root: root)
      ArchSpec::Facts.write(path, commit: 'abc123', dirty: false, **facts)
      first = File.read(path)
      ArchSpec::Facts.write(path, commit: 'abc123', dirty: false, **ArchSpec::Reflect.facts_for([post, user], root: root))

      assert_equal first, File.read(path)
      refute_match(/\d{4}-\d{2}-\d{2}/, first)

      loaded = ArchSpec::Facts.load("#{root}/archspec_facts", root: root)
      assert loaded.present?
      assert_equal %w[User Session], loaded.references.map(&:target)
      assert_equal 'abc123', loaded.files.first.commit
    end
  end
end
