# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path('../lib', __dir__)

require 'archspec'
require 'fileutils'
require 'minitest/autorun'
require 'tmpdir'

class ArchSpecTest < Minitest::Test
  private

  def with_project(&block)
    Dir.mktmpdir('archspec', &block)
  end

  def write(path, contents)
    full_path = File.expand_path(path)
    FileUtils.mkdir_p(File.dirname(full_path))
    File.write(full_path, contents)
  end

  def diagnostics_for(definition, root)
    graph = ArchSpec::Analyzer.analyze(definition, root: root)
    ArchSpec::Evaluator.evaluate(definition, graph)
  end
end
