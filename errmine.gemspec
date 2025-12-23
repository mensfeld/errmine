# frozen_string_literal: true

require_relative 'lib/errmine/version'

Gem::Specification.new do |spec|
  spec.name          = 'errmine'
  spec.version       = Errmine::VERSION
  spec.authors       = ['Maciej Mensfeld']
  spec.email         = ['contact@mensfeld.pl']
  spec.summary       = 'Dead simple exception tracking for Redmine'
  spec.description   = 'Automatically create and update Redmine issues from Ruby/Rails exceptions. Zero dependencies.'
  spec.homepage      = 'https://github.com/mensfeld/errmine'
  spec.license       = 'MIT'

  spec.required_ruby_version = '>= 2.7.0'

  spec.files         = Dir['lib/**/*', 'README.md', 'LICENSE', 'CHANGELOG.md']
  spec.require_paths = ['lib']

  spec.metadata = {
    'homepage_uri' => spec.homepage,
    'source_code_uri' => spec.homepage,
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md",
    'rubygems_mfa_required' => 'true'
  }

end
