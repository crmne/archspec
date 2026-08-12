# frozen_string_literal: true

require 'test_helper'

class ValueObjectTest < ArchSpecTest
  Point = ArchSpec::ValueObject.define(:x, :y)

  def test_value_objects_accept_keywords
    point = Point.new(x: 12, y: 3)

    assert_equal 12, point.x
    assert_equal 3, point.y
  end

  def test_value_objects_are_immutable
    point = Point.new(12, 3)

    assert_predicate point, :frozen?
    refute_respond_to point, :x=
  end

  def test_value_objects_can_copy_with_changes
    point = Point.new(12, 3)
    updated = point.with(x: 13)

    assert_equal Point.new(13, 3), updated
    assert_equal 12, point.x
  end

  def test_value_objects_reject_incomplete_values
    assert_raises(ArgumentError) do
      Point.new(12)
    end
  end
end
