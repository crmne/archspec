$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "archspec"
require "fileutils"
require "minitest/autorun"
require "tmpdir"

class ArchSpecTest < Minitest::Test
  private

  def with_project
    Dir.mktmpdir("archspec") do |dir|
      yield dir
    end
  end

  def write(path, contents)
    full_path = File.expand_path(path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, contents)
  end
end
