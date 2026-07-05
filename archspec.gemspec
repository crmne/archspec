# frozen_string_literal: true

require_relative 'lib/archspec/version'

Gem::Specification.new do |spec|
  spec.name = 'archspec'
  spec.version = ArchSpec::VERSION
  spec.authors = ['Carmine Paolino']
  spec.email = ['carmine@paolino.me']

  spec.summary = 'Architecture linter for Ruby and Rails.'
  spec.description = 'A static architecture linter for Ruby and Rails. Declare your ' \
                     'components, dependencies, and boundaries in one file, then check ' \
                     'every change in CI. It reads source with Prism and never boots the app.'
  spec.homepage = 'https://archspecrb.dev'
  spec.license = 'MIT'

  spec.required_ruby_version = '>= 3.1.3'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = 'https://github.com/crmne/archspec'
  spec.metadata['changelog_uri'] = "#{spec.metadata['source_code_uri']}/releases"
  spec.metadata['documentation_uri'] = "#{spec.homepage}/getting-started/"
  spec.metadata['bug_tracker_uri'] = "#{spec.metadata['source_code_uri']}/issues"
  spec.metadata['rubygems_mfa_required'] = 'true'

  spec.files = Dir['exe/*', 'lib/**/*.rb', 'README.md', 'LICENSE.txt'].select { |file| File.file?(file) }
  spec.bindir = 'exe'
  spec.executables = ['archspec']
  spec.require_paths = ['lib']

  spec.add_dependency 'prism', '>= 1.0'

  spec.add_development_dependency 'minitest', '>= 5.20', '< 6'
  spec.add_development_dependency 'rake', '>= 13.0'
  spec.add_development_dependency 'rdoc', '>= 6.6'
end
