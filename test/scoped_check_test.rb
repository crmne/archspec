# frozen_string_literal: true

require 'test_helper'
require 'json'
require 'minitest/mock'
require 'stringio'

class ScopedCheckTest < ArchSpecTest
  def test_a_scoped_check_over_a_snapshot_reads_only_the_named_paths
    with_project do |root|
      write_app(root)
      assert_equal 0, archspec(root, ["snapshot"])
      write "#{root}/app/models/user.rb", "class User\n  def audit = UsersController\nend\n"
      FileUtils.rm_rf("#{root}/.archspec/cache")

      parsed = []
      original = Prism.method(:parse_file)
      scoped = Prism.stub(:parse_file, ->(path) { parsed << path && original.call(path) }) do
        check_json(root, ['app/models'])
      end

      assert_equal ["#{root}/app/models/user.rb"], parsed
      assert_equal check_json(root, ['app/models']), scoped
      assert_equal ['dependencies.forbid'], scoped.fetch('violations').map { |v| v['rule'] }
    end
  end

  def test_a_scoped_check_without_a_cache_reads_everything
    with_project do |root|
      write_app(root, cache: false)
      assert_equal 0, archspec(root, ["snapshot"])
      parsed = []
      original = Prism.method(:parse_file)
      Prism.stub(:parse_file, ->(path) { parsed << path && original.call(path) }) do
        check_json(root, ['app/models'])
      end

      assert_equal 2, parsed.size
    end
  end

  def test_a_scoped_check_without_a_snapshot_reads_everything
    with_project do |root|
      write_app(root)
      parsed = []
      original = Prism.method(:parse_file)
      Prism.stub(:parse_file, ->(path) { parsed << path && original.call(path) }) do
        check_json(root, ['app/models'])
      end

      assert_equal 2, parsed.size
    end
  end

  def test_a_snapshot_taken_under_other_patterns_is_not_reused
    with_project do |root|
      write_app(root)
      assert_equal 0, archspec(root, ["snapshot"])
      write "#{root}/Archspec.rb", File.read("#{root}/Archspec.rb") + "ignore 'app/helpers/**/*.rb'\n"
      FileUtils.rm_rf("#{root}/.archspec/cache")

      parsed = []
      original = Prism.method(:parse_file)
      Prism.stub(:parse_file, ->(path) { parsed << path && original.call(path) }) do
        check_json(root, ['app/models'])
      end

      assert_equal 2, parsed.size
    end
  end

  def test_a_file_the_snapshot_never_saw_is_read
    with_project do |root|
      write_app(root)
      assert_equal 0, archspec(root, ["snapshot"])
      write "#{root}/app/models/account.rb", "class Account\n  def owner = UsersController\nend\n"

      scoped = check_json(root, ['app/controllers'])

      assert_equal 3, scoped.fetch('files')
      assert_equal [], scoped.fetch('violations')
      full = check_json(root, [])
      assert_equal ['app/models/account.rb'], full.fetch('violations').map { |v| v['path'] }
    end
  end

  private

  def write_app(root, cache: true)
    write "#{root}/Archspec.rb", <<~RUBY
      component :models, in: "app/models/**/*.rb"
      component :controllers, in: "app/controllers/**/*.rb"
      models.cannot_use :controllers
      #{'cache' if cache}
    RUBY
    write "#{root}/app/models/user.rb", "class User\nend\n"
    write "#{root}/app/controllers/users_controller.rb", "class UsersController\n  def show = User\nend\n"
  end

  def archspec(root, argv)
    Dir.chdir(root) { ArchSpec::CLI.run(argv, output: StringIO.new, error: StringIO.new) }
  end

  def check_json(root, paths)
    output = StringIO.new
    Dir.chdir(root) { ArchSpec::CLI.run(['check', '--format', 'json', *paths], output: output, error: output) }
    JSON.parse(output.string)
  end
end
