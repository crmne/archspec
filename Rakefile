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

  desc 'Audit generated metadata, discovery files, and internal links'
  task :audit do
    sh 'docs/bin/audit-seo.rb', 'docs/_site'
  end
end

namespace :torture do
  %w[discourse fizzy mastodon synthetic].each do |app|
    desc "Run ArchSpec against a pinned #{app} checkout"
    task app.to_sym do
      ruby "test/torture/run.rb #{app}"
    end
  end
end

desc 'Run ArchSpec against pinned Discourse, Fizzy, and Mastodon checkouts and the synthetic monolith'
task torture: %w[torture:discourse torture:fizzy torture:mastodon torture:synthetic]

task default: %i[test architecture]
