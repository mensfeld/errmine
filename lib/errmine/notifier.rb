# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'
require 'digest'
require 'singleton'

# @see Errmine
module Errmine
  # Core notifier that handles exception reporting to Redmine.
  # Manages checksum generation, rate limiting, and API communication.
  class Notifier
    include Singleton

    # HTTP connection timeout in seconds
    CONNECT_TIMEOUT = 5

    # HTTP read timeout in seconds
    READ_TIMEOUT = 10

    # Maximum number of entries in the rate limit cache
    MAX_CACHE_SIZE = 500

    # Maximum length of exception message in issue subject
    SUBJECT_MESSAGE_LENGTH = 60

    # Initializes the notifier with empty cache
    def initialize
      @cache = {}
      @mutex = Mutex.new
    end

    # Notifies Redmine about an exception
    #
    # @param exception [Exception] the exception to report
    # @param context [Hash] additional context (url, user, etc.)
    # @return [Hash, nil] the created/updated issue or nil on failure
    def notify(exception, context = {})
      checksum = generate_checksum(exception)

      return nil if rate_limited?(checksum)

      record_occurrence(checksum)

      result = find_existing_issue(checksum)

      case result
      when :error
        nil
      when nil
        create_issue(exception, context, checksum)
      else
        update_issue(result, exception, context)
      end
    end

    # Clears the rate limit cache
    #
    # @return [void]
    def reset_cache!
      @mutex.synchronize { @cache.clear }
    end

    private

    # Returns the Errmine configuration
    #
    # @return [Errmine::Configuration]
    def config
      Errmine.configuration
    end

    # Generates an 8-character checksum for the exception
    #
    # @param exception [Exception]
    # @return [String]
    def generate_checksum(exception)
      first_app_line = first_app_backtrace_line(exception)
      data = "#{exception.class}:#{exception.message}:#{first_app_line}"
      Digest::MD5.hexdigest(data)[0, 8]
    end

    # Finds the first backtrace line from the application
    #
    # @param exception [Exception]
    # @return [String]
    def first_app_backtrace_line(exception)
      return '' unless exception.backtrace

      exception.backtrace.find { |line| line.include?('/app/') } ||
        exception.backtrace.first ||
        ''
    end

    # Checks if the checksum is rate limited
    #
    # @param checksum [String]
    # @return [Boolean]
    def rate_limited?(checksum)
      @mutex.synchronize do
        last_seen = @cache[checksum]
        return false unless last_seen

        Time.now - last_seen < config.cooldown
      end
    end

    # Records the occurrence of a checksum
    #
    # @param checksum [String]
    # @return [void]
    def record_occurrence(checksum)
      @mutex.synchronize do
        cleanup_cache if @cache.size >= MAX_CACHE_SIZE
        @cache[checksum] = Time.now
      end
    end

    # Cleans up old entries from the cache
    #
    # @return [void]
    def cleanup_cache
      cutoff = Time.now - config.cooldown
      @cache.delete_if { |_, time| time < cutoff }

      return unless @cache.size >= MAX_CACHE_SIZE

      sorted = @cache.sort_by { |_, time| time }
      to_remove = sorted.first(@cache.size - (MAX_CACHE_SIZE / 2))
      to_remove.each_key { |key| @cache.delete(key) }
    end

    # Finds an existing open issue with the given checksum
    #
    # @param checksum [String]
    # @return [Hash, Symbol, nil] the issue hash, :error on failure, or nil if not found
    def find_existing_issue(checksum)
      uri = build_uri('/issues.json')
      uri.query = URI.encode_www_form(
        project_id: config.project_id,
        'subject' => "~[#{checksum}]",
        status_id: 'open'
      )

      response = http_get(uri)
      return :error unless response

      data = JSON.parse(response.body)
      issues = data['issues'] || []

      issues.find { |issue| issue['subject']&.include?("[#{checksum}]") }
    rescue JSON::ParserError => e
      warn "[Errmine] Failed to parse response: #{e.message}"
      :error
    end

    # Creates a new issue in Redmine
    #
    # @param exception [Exception]
    # @param context [Hash]
    # @param checksum [String]
    # @return [Hash, nil]
    def create_issue(exception, context, checksum)
      uri = build_uri('/issues.json')

      subject = build_subject(checksum, 1, exception)
      description = build_description(exception, context)

      payload = {
        issue: {
          project_id: config.project_id,
          tracker_id: config.tracker_id,
          subject: subject,
          description: description
        }
      }

      response = http_post(uri, payload)
      return nil unless response

      data = JSON.parse(response.body)
      data['issue']
    rescue JSON::ParserError => e
      warn "[Errmine] Failed to parse response: #{e.message}"
      nil
    end

    # Updates an existing issue with new occurrence
    #
    # @param issue [Hash]
    # @param exception [Exception]
    # @param context [Hash]
    # @return [Net::HTTPResponse, nil]
    def update_issue(issue, exception, context)
      issue_id = issue['id']
      current_subject = issue['subject']

      new_count = extract_count(current_subject) + 1
      checksum = extract_checksum(current_subject)

      new_subject = build_subject(checksum, new_count, exception)
      notes = build_journal_note(new_count, context, exception)

      uri = build_uri("/issues/#{issue_id}.json")

      payload = {
        issue: {
          subject: new_subject,
          notes: notes
        }
      }

      http_put(uri, payload)
    end

    # Builds the issue subject line
    #
    # @param checksum [String]
    # @param count [Integer]
    # @param exception [Exception]
    # @return [String]
    def build_subject(checksum, count, exception)
      message = exception.message.to_s
      truncated = message.length > SUBJECT_MESSAGE_LENGTH ? "#{message[0, SUBJECT_MESSAGE_LENGTH]}..." : message
      truncated = truncated.gsub(/[\r\n]+/, ' ').strip

      "[#{checksum}][#{count}] #{exception.class}: #{truncated}"
    end

    # Builds the issue description in Textile format
    #
    # @param exception [Exception]
    # @param context [Hash]
    # @return [String]
    def build_description(exception, context)
      lines = []
      lines << "**Exception:** @#{exception.class}@"
      lines << "**Message:** #{exception.message}"
      lines << "**App:** #{config.app_name}"
      lines << "**First seen:** #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << ''

      lines << "**URL:** #{context[:url]}" if context[:url]

      lines << "**User:** #{context[:user]}" if context[:user]

      context.each do |key, value|
        next if %i[url user].include?(key)

        lines << "**#{key.to_s.capitalize}:** #{value}"
      end

      lines << ''
      lines << 'h3. Backtrace'
      lines << ''
      lines << '<pre>'
      lines << format_backtrace(exception)
      lines << '</pre>'

      lines.join("\n")
    end

    # Builds a journal note for issue updates
    #
    # @param count [Integer]
    # @param context [Hash]
    # @param exception [Exception]
    # @return [String]
    def build_journal_note(count, context, exception)
      lines = []
      lines << "Occurred again (*#{count}x*) at #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << ''

      lines << "URL: #{context[:url]}" if context[:url]
      lines << "User: #{context[:user]}" if context[:user]

      lines << ''
      lines << '<pre>'
      lines << format_backtrace(exception, limit: 10)
      lines << '</pre>'

      lines.join("\n")
    end

    # Formats the exception backtrace
    #
    # @param exception [Exception]
    # @param limit [Integer]
    # @return [String]
    def format_backtrace(exception, limit: 20)
      return 'No backtrace available' unless exception.backtrace

      exception.backtrace.first(limit).join("\n")
    end

    # Extracts the occurrence count from issue subject
    #
    # @param subject [String, nil]
    # @return [Integer]
    def extract_count(subject)
      match = subject&.match(/\]\[(\d+)\]/)
      match ? match[1].to_i : 0
    end

    # Extracts the checksum from issue subject
    #
    # @param subject [String, nil]
    # @return [String]
    def extract_checksum(subject)
      match = subject&.match(/\[([a-f0-9]{8})\]/)
      match ? match[1] : ''
    end

    # Builds a URI for the Redmine API
    #
    # @param path [String]
    # @return [URI]
    def build_uri(path)
      base = config.redmine_url.chomp('/')
      URI.parse("#{base}#{path}")
    end

    # Performs an HTTP GET request
    #
    # @param uri [URI]
    # @return [Net::HTTPResponse, nil]
    def http_get(uri)
      http_request(uri) do |http|
        request = Net::HTTP::Get.new(uri)
        request['X-Redmine-API-Key'] = config.api_key
        http.request(request)
      end
    end

    # Performs an HTTP POST request
    #
    # @param uri [URI]
    # @param payload [Hash]
    # @return [Net::HTTPResponse, nil]
    def http_post(uri, payload)
      http_request(uri) do |http|
        request = Net::HTTP::Post.new(uri)
        request['X-Redmine-API-Key'] = config.api_key
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(payload)
        http.request(request)
      end
    end

    # Performs an HTTP PUT request
    #
    # @param uri [URI]
    # @param payload [Hash]
    # @return [Net::HTTPResponse, nil]
    def http_put(uri, payload)
      http_request(uri) do |http|
        request = Net::HTTP::Put.new(uri)
        request['X-Redmine-API-Key'] = config.api_key
        request['Content-Type'] = 'application/json'
        request.body = JSON.generate(payload)
        http.request(request)
      end
    end

    # Executes an HTTP request with error handling
    #
    # @param uri [URI]
    # @return [Net::HTTPResponse, nil]
    def http_request(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = CONNECT_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      response = yield(http)

      unless response.is_a?(Net::HTTPSuccess)
        warn "[Errmine] HTTP #{response.code}: #{response.message}"
        return nil
      end

      response
    rescue Net::OpenTimeout, Net::ReadTimeout => e
      warn "[Errmine] Timeout: #{e.message}"
      nil
    rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, SocketError => e
      warn "[Errmine] Connection error: #{e.message}"
      nil
    rescue StandardError => e
      warn "[Errmine] HTTP error: #{e.message}"
      nil
    end
  end
end
