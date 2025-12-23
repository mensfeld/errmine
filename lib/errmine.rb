# frozen_string_literal: true

require_relative 'errmine/version'
require_relative 'errmine/notifier'

# Dead simple exception tracking for Redmine.
# Automatically creates and updates Redmine issues from Ruby/Rails exceptions.
module Errmine
  # Base error class for Errmine-specific errors
  class Error < StandardError; end

  # Raised when configuration is invalid
  class ConfigurationError < Error; end

  # Configuration class for Errmine settings
  class Configuration
    # @return [String, nil] Redmine server URL
    attr_accessor :redmine_url

    # @return [String, nil] Redmine API key
    attr_accessor :api_key

    # @return [String] Redmine project identifier
    attr_accessor :project_id

    # @return [Integer] Redmine tracker ID (default: 1 for Bug)
    attr_accessor :tracker_id

    # @return [String] Application name shown in issues
    attr_accessor :app_name

    # @return [Boolean] Whether notifications are enabled
    attr_accessor :enabled

    # @return [Integer] Cooldown period in seconds between same-error notifications
    attr_accessor :cooldown

    def initialize
      @redmine_url = ENV.fetch('REDMINE_URL', nil)
      @api_key     = ENV.fetch('REDMINE_API_KEY', nil)
      @project_id  = ENV['REDMINE_PROJECT'] || 'bug-tracker'
      @tracker_id  = 1
      @app_name    = ENV['APP_NAME'] || 'unknown'
      @enabled     = true
      @cooldown    = 300
    end

    # Checks if the configuration has required values
    #
    # @return [Boolean] true if redmine_url and api_key are present
    def valid?
      !redmine_url.nil? && !redmine_url.empty? &&
        !api_key.nil? && !api_key.empty?
    end
  end

  class << self
    # Returns the current configuration instance
    #
    # @return [Configuration] the configuration instance
    def configuration
      @configuration ||= Configuration.new
    end

    # Yields the configuration for modification
    #
    # @yield [Configuration] the configuration instance
    # @return [Configuration] the configuration instance
    def configure
      yield(configuration) if block_given?
      configuration
    end

    # Resets the configuration to default values
    #
    # @return [Configuration] the new configuration instance
    def reset_configuration!
      @configuration = Configuration.new
    end

    # Notifies Redmine about an exception
    #
    # @param exception [Exception] the exception to report
    # @param context [Hash] additional context (url, user, etc.)
    # @return [Hash, nil] the created/updated issue or nil on failure
    def notify(exception, context = {})
      return unless configuration.enabled
      return unless configuration.valid?

      Notifier.instance.notify(exception, context)
    rescue StandardError => e
      warn "[Errmine] Failed to notify: #{e.message}"
      nil
    end
  end
end

require_relative 'errmine/railtie' if defined?(Rails::Railtie)
