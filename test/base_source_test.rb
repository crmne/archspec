# frozen_string_literal: true

require 'test_helper'

class BaseSourceTest < ArchSpecTest
  def test_extensions_requires_an_implementation
    assert_raises(NotImplementedError) { ArchSpec::Sources::Base.extensions }
  end

  def test_comments_requires_an_implementation
    source = ArchSpec::Sources::Base.allocate

    assert_raises(NotImplementedError) { source.comments }
  end

  def test_prism_requires_an_implementation
    source = ArchSpec::Sources::Base.allocate

    assert_raises(NotImplementedError) { source.prism }
  end

  def test_parse_file_is_private_and_requires_an_implementation
    source = ArchSpec::Sources::Base.allocate

    assert_includes ArchSpec::Sources::Base.private_instance_methods, :parse_file
    assert_raises(NotImplementedError) { source.send(:parse_file) }
  end
end
