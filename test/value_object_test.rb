# frozen_string_literal: true

require 'test_helper'

class ValueObjectTest < ArchSpecTest
  def test_value_objects_accept_keywords
    location = ArchSpec::SourceLocation.new(path: '/app/user.rb', line: 12, column: 3)

    assert_equal '/app/user.rb', location.path
    assert_equal 12, location.line
    assert_equal 3, location.column
  end

  def test_value_objects_are_immutable
    location = ArchSpec::SourceLocation.new('/app/user.rb', 12, 3)

    assert_predicate location, :frozen?
    refute_respond_to location, :line=
  end

  def test_value_objects_can_copy_with_changes
    location = ArchSpec::SourceLocation.new('/app/user.rb', 12, 3)
    updated = location.with(line: 13)

    assert_equal ArchSpec::SourceLocation.new('/app/user.rb', 13, 3), updated
    assert_equal 12, location.line
  end

  def test_value_objects_reject_incomplete_values
    assert_raises(ArgumentError) do
      ArchSpec::SourceLocation.new('/app/user.rb')
    end
  end
end
