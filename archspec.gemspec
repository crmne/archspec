require_relative "lib/archspec/version"

Gem::Specification.new do |spec|
  spec.name = "archspec"
  spec.version = ArchSpec::VERSION
  spec.authors = ["ArchSpec contributors"]

  spec.summary = "Architecture fitness functions for Ruby and Rails."
  spec.description = "Static, convention-aware architecture checks for Ruby and Rails codebases."
  spec.homepage = "https://archspec.dev"
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/crmne/archspec"
  spec.metadata["changelog_uri"] = "#{spec.metadata["source_code_uri"]}/releases"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/getting-started/"
  spec.metadata["bug_tracker_uri"] = "#{spec.metadata["source_code_uri"]}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["exe/*", "lib/**/*.rb", "README.md", "LICENSE.txt"].select { |file| File.file?(file) }
  spec.bindir = "exe"
  spec.executables = ["archspec"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0"

  spec.add_development_dependency "minitest", ">= 5.20"
  spec.add_development_dependency "rake", ">= 13.0"
end
