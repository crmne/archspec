require "test_helper"
require "stringio"

class FixtureAppTest < ArchSpecTest
  FIXTURE_ROOT = File.expand_path("fixtures/rails_app", __dir__)

  def test_rails_shaped_fixture_passes
    output = StringIO.new
    status = Dir.chdir(FIXTURE_ROOT) { ArchSpec::CLI.run(["check"], output: output, error: StringIO.new) }

    assert_equal 0, status, output.string
    assert_match(/ArchSpec passed/, output.string)
  end

  def test_explain_fixture_component_assignment
    output = StringIO.new
    status = Dir.chdir(FIXTURE_ROOT) { ArchSpec::CLI.run(["explain", "app/services/create_user.rb"], output: output, error: StringIO.new) }

    assert_equal 0, status
    assert_match(/services: matched file pattern app\/services\/\*\*\/\*\.rb/, output.string)
    assert_match(/outgoing facts:/, output.string)
  end
end
