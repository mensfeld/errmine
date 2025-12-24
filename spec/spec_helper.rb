# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  enable_coverage :branch
  minimum_coverage line: 95, branch: 80
  add_filter '/spec/'
end

require 'webmock/rspec'
require 'errmine'
require 'errmine/middleware'

WebMock.disable_net_connect!

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.example_status_persistence_file_path = 'spec/examples.txt'
  config.disable_monkey_patching!
  config.warnings = true

  config.default_formatter = 'doc' if config.files_to_run.one?

  config.order = :random
  Kernel.srand config.seed

  config.before do
    Errmine.reset_configuration!
    Errmine::Notifier.instance.reset_cache!
    WebMock.reset!
  end
end

def configure_errmine
  Errmine.configure do |config|
    config.redmine_url = 'https://redmine.example.com'
    config.api_key = 'test-api-key'
    config.project_id = 'test-project'
    config.app_name = 'test-app'
  end
end

def sample_exception(message = 'Something went wrong')
  raise StandardError, message
rescue StandardError => e
  e
end

def sample_exception_with_class(klass, message = 'Something went wrong')
  raise klass, message
rescue StandardError => e
  e
end
