# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'minitest/mock'
require 'stringio'

class ParseCacheTest < ArchSpecTest
  def test_a_cached_run_prints_exactly_what_an_uncached_run_prints
    with_project do |root|
      write_app(root)
      uncached = check_json(root)

      write "#{root}/Archspec.rb", File.read("#{root}/Archspec.rb") + "cache\n"
      first = check_json(root)
      second = check_json(root)

      assert_equal uncached, first
      assert_equal uncached, second
      assert_path_exists "#{root}/.archspec/cache/.gitignore"
      assert_equal 2, Dir.glob("#{root}/.archspec/cache/*.marshal").size
    end
  end

  def test_a_hit_replays_the_facts_without_parsing
    with_project do |root|
      write_app(root, cache: true)
      definition = definition_for(root)
      ArchSpec::Analyzer.analyze(definition, root: root)

      Prism.stub(:parse_file, ->(path) { raise "parsed #{path} on a cache hit" }) do
        graph = ArchSpec::Analyzer.analyze(definition, root: root)

        user = graph.constants_named('User').first
        assert_equal %i[account account= build_account create_account create_account! reload_account trial? name],
                     user.method_definitions.map(&:name)
        assert_equal %i[name], user.method_definitions.select { |d| d.visibility == :private }.map(&:name)
        assert_equal Set['Trackable'], user.mixins[:include]
        assert_equal 'ApplicationRecord', user.superclass
        assert_equal %i[account], user.associations.map(&:name)
        types = graph.edges.select { |edge| edge.from_path == "#{root}/app/models/user.rb" }.map(&:type)
        assert_includes types, :inherits_from
        assert_includes types, :includes
        assert_includes types, :calls_named_method
        assert_equal 1, graph.files.fetch("#{root}/app/controllers/users_controller.rb").suppressions.size
      end
    end
  end

  def test_a_changed_file_misses_and_an_unchanged_one_hits
    with_project do |root|
      write_app(root, cache: true)
      definition = definition_for(root)
      ArchSpec::Analyzer.analyze(definition, root: root)
      write "#{root}/app/models/user.rb", "class User < ApplicationRecord\n  def renamed; end\nend\n"

      parsed = []
      original = Prism.method(:parse_file)
      Prism.stub(:parse_file, lambda { |path|
        parsed << path
        original.call(path)
      }) do
        graph = ArchSpec::Analyzer.analyze(definition, root: root)
        assert_equal ["#{root}/app/models/user.rb"], parsed
        assert_equal %i[renamed], graph.constants_named('User').first.method_definitions.map(&:name)
      end
    end
  end

  def test_an_unreadable_entry_is_a_miss
    with_project do |root|
      write_app(root, cache: true)
      definition = definition_for(root)
      ArchSpec::Analyzer.analyze(definition, root: root)
      Dir.glob("#{root}/.archspec/cache/*.marshal").each { |entry| File.write(entry, 'not a cache entry') }

      graph = ArchSpec::Analyzer.analyze(definition, root: root)

      assert_equal %w[User UsersController], graph.constants.map(&:name).sort
    end
  end

  def test_the_cache_directory_is_opt_in
    with_project do |root|
      write_app(root)
      check_json(root)

      refute_path_exists "#{root}/.archspec/cache"
    end
  end

  private

  def write_app(root, cache: false)
    write "#{root}/Archspec.rb", <<~RUBY
      component :models, in: "app/models/**/*.rb"
      component :controllers, in: "app/controllers/**/*.rb"
      models.cannot_use :controllers
      #{'cache' if cache}
    RUBY
    write "#{root}/app/models/user.rb", <<~RUBY
      class User < ApplicationRecord
        include Trackable
        belongs_to :account

        def trial?
          UsersController.new.audit
        end

        private

        def name; end
      end
    RUBY
    write "#{root}/app/controllers/users_controller.rb", <<~RUBY
      class UsersController
        # archspec:disable-next-line dependencies.forbid
        def audit = User
      end
    RUBY
  end

  def definition_for(root)
    definition = ArchSpec::Definition.new
    definition.base_dir = root
    definition.extend(ArchSpec::DSL::Context)
    definition.instance_eval(File.read("#{root}/Archspec.rb"), "#{root}/Archspec.rb")
    definition
  end

  def check_json(root)
    output = StringIO.new
    Dir.chdir(root) { ArchSpec::CLI.run(['check', '--format', 'json'], output: output, error: output) }
    JSON.parse(output.string)
  end
end
