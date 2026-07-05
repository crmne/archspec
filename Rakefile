# frozen_string_literal: true

require 'rake/testtask'

Rake::TestTask.new(:test) do |task|
  task.libs << 'test'
  task.pattern = 'test/**/*_test.rb'
end

task :architecture do
  sh 'exe/archspec check'
end

namespace :docs do
  desc 'Build the RDoc API docs into docs/_site/api'
  task :api do
    sh 'docs/bin/build-api.sh', 'docs/_site/api'
  end
end

namespace :torture do
  %w[discourse mastodon].each do |app|
    desc "Run ArchSpec against a pinned #{app} checkout"
    task app.to_sym do
      ruby "test/torture/run.rb #{app}"
    end
  end
end

desc 'Run ArchSpec against pinned Discourse and Mastodon checkouts'
task torture: %w[torture:discourse torture:mastodon]

task default: %i[test architecture]
