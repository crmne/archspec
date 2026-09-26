# frozen_string_literal: true

require 'test_helper'

class RubySourceTest < ArchSpecTest
  def test_extensions_and_index_paths
    assert_equal %w[.rb .rake], ArchSpec::Sources::Ruby.extensions
    assert ArchSpec::Sources::Ruby.rubydex_indexable?

    with_project do |root|
      %w[rb rake].each do |extension|
        path = "#{root}/source.#{extension}"
        write path, 'User.count'
        source = ArchSpec::Sources::Ruby.new(path)
        assert_instance_of Prism::ProgramNode, source.prism
      end
    end
  end

  def test_ruby_comments_use_original_positions_and_a_retained_parse_result
    with_project do |root|
      path = "#{root}/source.rb"
      write path, "  # first\nUser.count # second\n"
      source = ArchSpec::Sources::Ruby.new("#{root}/./source.rb")
      write path, 'class'

      assert_equal path, source.path
      assert_equal [
        ArchSpec::Sources::Comment.new('# first', 1, 2),
        ArchSpec::Sources::Comment.new('# second', 2, 11)
      ], source.comments
      assert_empty source.parse_errors
      assert_equal 'User.count', source.prism.statements.body.first.slice
    end
  end

  def test_parse_errors_use_source_specific_locations
    with_project do |root|
      ruby_path = "#{root}/source.rb"
      write ruby_path, "class\n"
      errors = ArchSpec::Sources::Ruby.new(ruby_path).parse_errors

      refute_empty errors
      assert errors.all? { |error| error.location.path == ruby_path }
      assert errors.all? { |error| error.location.line >= 1 && error.location.column >= 1 }
    end
  end
end
