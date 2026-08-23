# frozen_string_literal: true

require 'test_helper'
require 'stringio'
require 'yaml'

class RubydexTest < ArchSpecTest
  def test_a_reference_the_parser_could_not_resolve_is_written
    facts = facts_for(
      { 'app/models/post.rb' => "class Post < ApplicationRecord\n  include Searchable\nend\n" },
      resolution('app/models/post.rb', 2, 'Searchable', in_workspace: false)
    )

    assert_equal [['Post', 'app/models/post.rb', 2, 'Searchable', 'rubydex-gem']], rows(facts)
    assert_equal({}, facts[:misses])
  end

  def test_a_workspace_target_is_named_as_such
    facts = facts_for(
      { 'app/models/post.rb' => "class Post\n  AUTHOR = Writer::Profile\nend\n" },
      resolution('app/models/post.rb', 2, 'Writer::Profile', in_workspace: true)
    )

    assert_equal [['Post', 'app/models/post.rb', 2, 'Writer::Profile', 'rubydex-workspace']], rows(facts)
  end

  def test_a_reference_the_parser_already_resolved_is_counted_not_written
    facts = facts_for(
      {
        'app/models/post.rb' => "class Post\n  def author = User.new\nend\n",
        'app/models/user.rb' => "class User; end\n"
      },
      resolution('app/models/post.rb', 2, 'User', in_workspace: true)
    )

    assert_empty rows(facts)
    assert_equal({ 'already_resolved' => 1 }, facts[:misses])
  end

  def test_a_disagreement_between_the_resolvers_is_counted_not_written
    facts = facts_for(
      {
        'app/models/post.rb' => "class Post\n  def author = User.new\nend\n",
        'app/models/user.rb' => "class User; end\n"
      },
      resolution('app/models/post.rb', 2, 'Admin::User', in_workspace: true)
    )

    assert_empty rows(facts)
    assert_equal({ 'disagreed' => 1 }, facts[:misses])
  end

  def test_a_line_the_parser_saw_nothing_on_is_written
    facts = facts_for(
      { 'app/models/post.rb' => "class Post\n  def author = fetch(:User)\nend\n" },
      resolution('app/models/post.rb', 2, 'User', in_workspace: false)
    )

    assert_equal [['Post', 'app/models/post.rb', 2, 'User', 'rubydex-gem']], rows(facts)
  end

  def test_an_owner_outside_any_constant_is_the_file
    facts = facts_for(
      { 'app/models/search.rb' => "Searchable.configure\n" },
      resolution('app/models/search.rb', 1, 'Searchable', in_workspace: false)
    )

    assert_equal [['app/models/search.rb', 'app/models/search.rb', 1, 'Searchable', 'rubydex-gem']], rows(facts)
  end

  def test_the_name_a_line_declares_is_not_a_reference_to_it
    facts = facts_for(
      { 'app/models/post.rb' => "module Blog\n  class Post; end\nend\n" },
      resolution('app/models/post.rb', 1, 'Blog', in_workspace: true),
      resolution('app/models/post.rb', 2, 'Blog::Post', in_workspace: true)
    )

    assert_empty rows(facts)
    assert_equal({ 'declaration' => 2 }, facts[:misses])
  end

  def test_self_inside_a_class_is_not_a_reference_to_it
    facts = facts_for(
      { 'app/models/post.rb' => "class Post\n  extend self\nend\n" },
      resolution('app/models/post.rb', 2, 'Post', in_workspace: true)
    )

    assert_empty rows(facts)
    assert_equal({ 'self' => 1 }, facts[:misses])
  end

  def test_a_path_the_parser_resolved_deeper_covers_its_prefix
    facts = facts_for(
      {
        'app/models/post.rb' => "class Post\n  LIMIT = Settings::MAX\nend\n",
        'app/models/settings.rb' => "class Settings\n  MAX = 3\nend\n"
      },
      resolution('app/models/post.rb', 2, 'Settings', in_workspace: true)
    )

    assert_empty rows(facts)
    assert_equal({ 'already_resolved' => 1 }, facts[:misses])
  end

  def test_a_file_the_definition_never_parsed_is_counted_not_written
    facts = facts_for(
      { 'app/models/post.rb' => "class Post; end\n", 'spec/post_spec.rb' => "Post.new\n" },
      resolution('spec/post_spec.rb', 1, 'Post', in_workspace: true)
    )

    assert_empty rows(facts)
    assert_equal({ 'outside_source' => 1 }, facts[:misses])
  end

  def test_a_superclass_the_parser_resolved_is_already_resolved
    facts = facts_for(
      {
        'app/models/post.rb' => "class Post < Record; end\n",
        'app/models/record.rb' => "class Record; end\n"
      },
      resolution('app/models/post.rb', 1, 'Record', in_workspace: true)
    )

    assert_equal({ 'already_resolved' => 1 }, facts[:misses])
  end

  def test_misses_from_the_index_travel_with_the_producers_own
    facts = facts_for(
      { 'app/models/post.rb' => "class Post; end\n" },
      misses: { 'unresolved' => 3, 'diagnostic' => 1 }
    )

    assert_equal({ 'diagnostic' => 1, 'unresolved' => 3 }, facts[:misses])
    assert_equal 'archspec-rubydex', facts[:producer]
    assert_empty facts[:generated_methods]
  end

  def test_the_producer_version_carries_the_engine_version
    facts = facts_for({ 'app/models/post.rb' => "class Post; end\n" }, engine_version: '0.4.0')

    assert_equal "#{ArchSpec::VERSION} rubydex 0.4.0", facts[:producer_version]
  end

  def test_the_written_file_loads_and_its_edge_reaches_a_rule
    with_project do |root|
      write "#{root}/app/models/post.rb", "class Post\n  def search = Kernel.const_get('Searchable').new\nend\n"
      write "#{root}/lib/searchable.rb", "class Searchable; end\n"
      definition = ArchSpec.define do
        component :models, in: 'app/models/**/*.rb'
        component :search, in: 'lib/**/*.rb'
        models.cannot_use :search
      end
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      facts = ArchSpec::Rubydex.facts_for(graph, [resolution('app/models/post.rb', 2, 'Searchable', in_workspace: true)])
      FileUtils.mkdir_p("#{root}/archspec_facts")
      ArchSpec::Facts.write("#{root}/archspec_facts/rubydex.yml", commit: nil, dirty: false, **facts)

      diagnostics = diagnostics_for(definition, root)

      assert_equal ['dependencies.forbid'], diagnostics.map(&:rule).uniq
      assert_match 'rubydex.yml', diagnostics.first.evidence
    end
  end

  def test_the_bundle_is_read_from_the_roots_own_lockfile
    with_project do |root|
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"

      error = assert_raises(ArchSpec::Error) { ArchSpec::Rubydex.send(:bundle!, root) }
      assert_match 'no Gemfile.lock', error.message

      write "#{root}/Gemfile.lock", "GEM\n  specs:\n"
      assert_nil ArchSpec::Rubydex.send(:bundle!, root)
    end
  end

  def test_the_cli_refuses_when_the_gem_is_not_loadable
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"

      error = StringIO.new
      status = without_rubydex do
        Dir.chdir(root) { ArchSpec::CLI.run(['reflect', '--rubydex'], output: StringIO.new, error: error) }
      end

      assert_equal 1, status
      assert_match 'rubydex gem is not loadable', error.string
    end
  end

  def test_the_cli_refuses_static_and_rubydex_together
    with_project do |root|
      write "#{root}/Archspec.rb", "component :models, in: 'app/models/**/*.rb'\n"

      error = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['reflect', '--static', '--rubydex'], output: StringIO.new, error: error) }

      assert_equal ArchSpec::CLI::USAGE_ERROR_STATUS, status
      assert_match 'different producers', error.string
    end
  end

  def test_the_real_gem_writes_the_fixture_apps_file
    skip 'set ARCHSPEC_RUBYDEX=1 to run the producer against the installed gem' unless ENV['ARCHSPEC_RUBYDEX']
    skip 'the rubydex gem is not loadable by this Ruby' unless rubydex_loadable?

    with_project do |root|
      FileUtils.cp_r("#{FIXTURE_APP}/.", root)
      write "#{root}/Gemfile", "source 'https://rubygems.org'\n"
      write "#{root}/Gemfile.lock", "GEM\n  specs:\n\nPLATFORMS\n  ruby\n\nDEPENDENCIES\n\nBUNDLED WITH\n   2.5.0\n"
      output = StringIO.new
      status = Dir.chdir(root) { ArchSpec::CLI.run(['reflect', '--rubydex'], output: output, error: StringIO.new) }

      assert_equal 0, status
      document = YAML.safe_load_file("#{root}/archspec_facts/rubydex.yml")
      assert_equal 'archspec-rubydex', document['producer']
      assert_match(/rubydex \d/, document['producer_version'])
      assert document['references'].all? { |entry| %w[rubydex-workspace rubydex-gem].include?(entry['determination']) }
      assert_equal document['references'].sort_by { |e| [e['owner'], e['target']] }, document['references']
    end
  end

  private

  FIXTURE_APP = File.expand_path('fixtures/rails_app', __dir__)

  def resolution(file, line, target, in_workspace:)
    ArchSpec::Rubydex::Resolution.new(file: file, line: line, target: target, in_workspace: in_workspace)
  end

  def facts_for(files, *resolutions, misses: {}, engine_version: nil)
    with_project do |root|
      files.each { |path, source| write "#{root}/#{path}", source }
      definition = ArchSpec.define { component :models, in: 'app/models/**/*.rb' }
      graph = ArchSpec::Analyzer.analyze(definition, root: root)
      ArchSpec::Rubydex.facts_for(graph, resolutions, misses: misses, engine_version: engine_version)
    end
  end

  def rows(facts)
    facts[:references].map { |entry| [entry.owner, entry.file, entry.line, entry.target, entry.determination] }
  end

  def without_rubydex
    ArchSpec::Rubydex.singleton_class.define_method(:require) do |name|
      raise LoadError, name if name == 'rubydex'

      super(name)
    end
    yield
  ensure
    ArchSpec::Rubydex.singleton_class.remove_method(:require)
  end

  def rubydex_loadable?
    require 'rubydex'
    true
  rescue LoadError
    false
  end
end
