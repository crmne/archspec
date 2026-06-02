require_relative "lib/archspec/version"

Gem::Specification.new do |spec|
  spec.name = "archspec"
  spec.version = ArchSpec::VERSION
  spec.authors = ["ArchSpec contributors"]

  spec.summary = "Architecture fitness functions for Ruby and Rails."
  spec.description = "Static, convention-aware architecture checks for Ruby and Rails codebases."
  spec.license = "MIT"

  spec.required_ruby_version = ">= 3.3"

  spec.metadata["allowed_push_host"] = "https://rubygems.org"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["exe/*", "lib/**/*.rb", "README.md", "LICENSE.txt"]
  spec.bindir = "exe"
  spec.executables = ["archspec"]
  spec.require_paths = ["lib"]

  spec.add_dependency "prism", ">= 1.0"

  spec.add_development_dependency "minitest", ">= 5.20"
  spec.add_development_dependency "rake", ">= 13.0"
end
