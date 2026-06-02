require "rake/testtask"

Rake::TestTask.new(:test) do |task|
  task.libs << "test"
  task.pattern = "test/**/*_test.rb"
end

task :architecture do
  sh "exe/archspec check"
end

task default: %i[test architecture]
