# frozen_string_literal: true

require 'test_helper'

# Slow: clones and analyzes real Rails apps. Opt in with ARCHSPEC_TORTURE=1.
# The synthetic app is generated locally and runs every time.
class TortureTest < ArchSpecTest
  %w[discourse fizzy mastodon].each do |app|
    define_method(:"test_#{app}") do
      skip 'set ARCHSPEC_TORTURE=1 to run torture tests' unless ENV['ARCHSPEC_TORTURE']

      assert system(RbConfig.ruby, File.expand_path('torture/run.rb', __dir__), app),
             "torture run failed for #{app}"
    end
  end

  def test_synthetic
    assert system(RbConfig.ruby, File.expand_path('torture/run.rb', __dir__), 'synthetic'),
           'torture run failed for synthetic'
  end
end
