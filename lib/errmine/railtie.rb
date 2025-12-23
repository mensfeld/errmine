# frozen_string_literal: true

require_relative 'middleware'

# @see Errmine
module Errmine
  # Rails integration via Railtie.
  # Automatically subscribes to Rails 7+ Error Reporting API when available.
  class Railtie < Rails::Railtie
    initializer 'errmine.configure_rails_initialization' do |_app|
      Rails.error.subscribe(ErrorSubscriber.new) if Rails.version >= '7.0'
    end

    # Error subscriber for Rails 7+ Error Reporting API
    class ErrorSubscriber
      # Called by Rails when an error is reported
      #
      # @param error [Exception] the reported error
      # @param handled [Boolean] whether the error was handled
      # @param severity [Symbol] the error severity
      # @param context [Hash]
      # @param source [String, nil] the error source
      # @return [void]
      def report(error, handled:, severity:, context: {}, source: nil)
        return if handled

        errmine_context = {}
        errmine_context[:url] = context[:url] if context[:url]
        errmine_context[:user] = context[:user]&.to_s if context[:user]
        errmine_context[:source] = source if source
        errmine_context[:severity] = severity if severity

        Errmine.notify(error, errmine_context)
      rescue StandardError => e
        warn "[Errmine] Error subscriber failed: #{e.message}"
      end
    end
  end
end
