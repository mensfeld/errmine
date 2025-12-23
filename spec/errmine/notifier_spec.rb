# frozen_string_literal: true

RSpec.describe Errmine::Notifier do
  let(:notifier) { described_class.instance }

  before { configure_errmine }

  # Helper to stub all HTTP requests with sensible defaults
  def stub_redmine_api(issues: [], create_response: { 'issue' => { 'id' => 1 } })
    stub_request(:get, %r{redmine\.example\.com/issues\.json})
      .to_return(status: 200, body: { 'issues' => issues }.to_json, headers: { 'Content-Type' => 'application/json' })

    stub_request(:post, %r{redmine\.example\.com/issues\.json})
      .to_return(status: 201, body: create_response.to_json, headers: { 'Content-Type' => 'application/json' })

    stub_request(:put, %r{redmine\.example\.com/issues/\d+\.json})
      .to_return(status: 200, body: '{}', headers: { 'Content-Type' => 'application/json' })
  end

  describe '#notify' do
    context 'when no existing issue' do
      before { stub_redmine_api }

      it 'creates a new issue' do
        exception = sample_exception('Test error message')
        result = notifier.notify(exception)

        expect(result).to be_a(Hash)
        expect(result['id']).to eq(1)
      end

      it 'sends correct headers' do
        exception = sample_exception
        notifier.notify(exception)

        expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json})
          .with(headers: { 'X-Redmine-API-Key' => 'test-api-key', 'Content-Type' => 'application/json' })
      end

      it 'includes exception details in request body' do
        exception = sample_exception_with_class(NoMethodError, 'undefined method foo')
        notifier.notify(exception)

        expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
          .with { |req| req.body.include?('NoMethodError') && req.body.include?('undefined method foo') })
      end
    end

    context 'when existing issue found' do
      it 'updates existing issue with matching checksum' do
        # Create with a known checksum pattern
        stub_request(:get, %r{redmine\.example\.com/issues\.json})
          .to_return(status: 200, body: { 'issues' => [{ 'id' => 456,
                                                         'subject' => '[abcd1234][5] StandardError: Test' }] }.to_json)

        stub_request(:put, %r{redmine\.example\.com/issues/456\.json})
          .to_return(status: 200, body: '{}')

        # Mock the checksum to match
        allow(notifier).to receive(:generate_checksum).and_return('abcd1234')

        exception = sample_exception('Test')
        notifier.notify(exception)

        expect(WebMock).to have_requested(:put, %r{redmine\.example\.com/issues/456\.json})
      end

      it 'increments the count in subject' do
        stub_request(:get, %r{redmine\.example\.com/issues\.json})
          .to_return(status: 200, body: { 'issues' => [{ 'id' => 456,
                                                         'subject' => '[abcd1234][5] StandardError: Test' }] }.to_json)

        stub_request(:put, %r{redmine\.example\.com/issues/456\.json})
          .to_return(status: 200, body: '{}')

        allow(notifier).to receive(:generate_checksum).and_return('abcd1234')

        exception = sample_exception('Test')
        notifier.notify(exception)

        expect(WebMock).to(have_requested(:put, %r{redmine\.example\.com/issues/456\.json})
          .with { |req| req.body.include?('[6]') })
      end

      it 'adds a journal note' do
        stub_request(:get, %r{redmine\.example\.com/issues\.json})
          .to_return(status: 200, body: { 'issues' => [{ 'id' => 456,
                                                         'subject' => '[abcd1234][5] StandardError: Test' }] }.to_json)

        stub_request(:put, %r{redmine\.example\.com/issues/456\.json})
          .to_return(status: 200, body: '{}')

        allow(notifier).to receive(:generate_checksum).and_return('abcd1234')

        exception = sample_exception('Test')
        notifier.notify(exception)

        expect(WebMock).to(have_requested(:put, %r{redmine\.example\.com/issues/456\.json})
          .with { |req| req.body.include?('notes') && req.body.include?('6x') })
      end
    end

    context 'with rate limiting' do
      before { stub_redmine_api }

      it 'skips notification for same error within cooldown' do
        exception = sample_exception('Same error')

        notifier.notify(exception)
        result = notifier.notify(exception)

        expect(result).to be_nil
        expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json}).once
      end

      it 'allows notification after cooldown expires' do
        Errmine.configuration.cooldown = 0

        exception = sample_exception('Same error')

        notifier.notify(exception)
        sleep(0.01)
        notifier.notify(exception)

        expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json}).twice
      end

      it 'allows different errors within cooldown' do
        exception1 = sample_exception('Error one')
        exception2 = sample_exception('Error two')

        notifier.notify(exception1)
        notifier.notify(exception2)

        expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json}).twice
      end
    end

    context 'with context' do
      before { stub_redmine_api }

      it 'includes URL in description' do
        exception = sample_exception
        notifier.notify(exception, { url: '/users/123' })

        expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
          .with { |req| req.body.include?('/users/123') })
      end

      it 'includes user in description' do
        exception = sample_exception
        notifier.notify(exception, { user: 'test@example.com' })

        expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
          .with { |req| req.body.include?('test@example.com') })
      end

      it 'includes custom context fields' do
        exception = sample_exception
        notifier.notify(exception, { environment: 'production', version: '1.2.3' })

        expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
          .with { |req| req.body.include?('production') && req.body.include?('1.2.3') })
      end
    end
  end

  describe 'checksum generation' do
    before { stub_redmine_api }

    it 'generates deterministic checksum' do
      exception = sample_exception('Consistent message')

      # First call
      notifier.notify(exception)
      notifier.reset_cache!

      # Capture the checksum from first request
      first_checksum = nil
      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with do |req|
          first_checksum = req.body.match(/\[([a-f0-9]{8})\]/)[1]
          true
        end)

      # Second call should produce same checksum
      notifier.notify(exception)

      expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?("[#{first_checksum}]") }.twice
    end

    it 'generates 8-character checksum' do
      exception = sample_exception

      notifier.notify(exception)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.match?(/\[[a-f0-9]{8}\]/) })
    end

    it 'generates different checksum for different exceptions' do
      exception1 = sample_exception('Error one')
      exception2 = sample_exception('Error two')

      checksums = []

      stub_request(:post, %r{redmine\.example\.com/issues\.json})
        .to_return do |request|
          checksums << request.body.match(/\[([a-f0-9]{8})\]/)[1]
          { status: 201, body: '{"issue":{"id":1}}' }
        end

      notifier.notify(exception1)
      notifier.reset_cache!
      notifier.notify(exception2)

      expect(checksums.uniq.size).to eq(2)
    end
  end

  describe 'subject formatting' do
    before { stub_redmine_api }

    it 'truncates long messages' do
      long_message = 'a' * 100
      exception = sample_exception(long_message)

      notifier.notify(exception)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with do |req|
          subject = JSON.parse(req.body)['issue']['subject']
          subject.include?('...') && subject.length < 150
        end)
    end

    it 'handles unicode in messages' do
      exception = sample_exception('Error with émojis and ünïcödé 日本語')

      notifier.notify(exception)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?('émojis') })
    end

    it 'replaces newlines in message' do
      exception = sample_exception("Error\nwith\nnewlines")

      notifier.notify(exception)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with do |req|
          subject = JSON.parse(req.body)['issue']['subject']
          !subject.include?("\n")
        end)
    end

    it 'includes exception class' do
      exception = sample_exception_with_class(ArgumentError, 'bad argument')

      notifier.notify(exception)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?('ArgumentError') })
    end
  end

  describe 'error handling' do
    it 'handles connection errors on search' do
      stub_request(:get, %r{redmine\.example\.com/issues\.json})
        .to_raise(Errno::ECONNREFUSED)

      exception = sample_exception
      expect { notifier.notify(exception) }.not_to raise_error
    end

    it 'handles timeout errors on search' do
      stub_request(:get, %r{redmine\.example\.com/issues\.json})
        .to_timeout

      exception = sample_exception
      expect { notifier.notify(exception) }.not_to raise_error
    end

    it 'handles invalid JSON response' do
      stub_request(:get, %r{redmine\.example\.com/issues\.json})
        .to_return(status: 200, body: 'not json')

      exception = sample_exception
      expect { notifier.notify(exception) }.not_to raise_error
    end

    it 'handles HTTP errors on search' do
      stub_request(:get, %r{redmine\.example\.com/issues\.json})
        .to_return(status: 500, body: 'Internal Server Error')

      exception = sample_exception
      expect { notifier.notify(exception) }.not_to raise_error
    end

    it 'handles unauthorized errors' do
      stub_request(:get, %r{redmine\.example\.com/issues\.json})
        .to_return(status: 401, body: 'Unauthorized')

      exception = sample_exception
      expect { notifier.notify(exception) }.not_to raise_error
    end
  end

  describe 'edge cases' do
    before { stub_redmine_api }

    it 'handles exception with nil backtrace' do
      exception = StandardError.new('No backtrace')

      expect { notifier.notify(exception) }.not_to raise_error
    end

    it 'handles exception with empty message' do
      exception = sample_exception('')

      expect { notifier.notify(exception) }.not_to raise_error
    end
  end

  describe '#reset_cache!' do
    it 'clears the rate limit cache' do
      stub_redmine_api

      exception = sample_exception

      notifier.notify(exception)
      notifier.reset_cache!
      notifier.notify(exception)

      expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json}).twice
    end
  end
end
