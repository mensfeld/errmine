# frozen_string_literal: true

# @see Errmine
module Errmine
  # Rack middleware that catches exceptions and reports them to Redmine.
  # Re-raises the exception after reporting to allow normal error handling.
  class Middleware
    # Creates a new middleware instance
    #
    # @param app [#call] the Rack application
    def initialize(app)
      @app = app
    end

    # Processes the request and catches any exceptions
    #
    # @param env [Hash] the Rack environment
    # @return [Array] the Rack response
    # @raise [Exception] re-raises any caught exception after reporting
    def call(env)
      @app.call(env)
    rescue Exception => e # rubocop:disable Lint/RescueException
      notify_exception(e, env)
      raise
    end

    private

    # Sends exception notification to Redmine
    #
    # @param exception [Exception] the caught exception
    # @param env [Hash] the Rack environment
    def notify_exception(exception, env)
      context = build_context(env)
      Errmine.notify(exception, context)
    rescue StandardError => e
      warn "[Errmine] Middleware error: #{e.message}"
    end

    # Builds context hash from Rack environment
    #
    # @param env [Hash] the Rack environment
    # @return [Hash] context with url, method, and user info
    def build_context(env)
      context = {}

      request_uri = env['REQUEST_URI'] || env['PATH_INFO']
      context[:url] = request_uri if request_uri

      request_method = env['REQUEST_METHOD']
      context[:method] = request_method if request_method

      if defined?(env['warden']) && env['warden']&.user
        user = env['warden'].user
        context[:user] = user.respond_to?(:email) ? user.email : user.to_s
      end

      context
    end
  end
end
