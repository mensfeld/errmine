# frozen_string_literal: true

RSpec.describe 'Integration', type: :integration do
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

  describe 'full workflow' do
    it 'creates issue when none exists' do
      stub_redmine_api(create_response: { 'issue' => { 'id' => 100 } })

      exception = sample_exception('Test error')
      result = Errmine.notify(exception, { url: '/test' })

      expect(result).to be_a(Hash)
      expect(result['id']).to eq(100)
      expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json})
    end

    it 'updates existing issue with matching checksum' do
      stub_request(:get, %r{redmine\.example\.com/issues\.json})
        .to_return(status: 200, body: { 'issues' => [{ 'id' => 100,
                                                       'subject' => '[abcd1234][1] StandardError: Test' }] }.to_json)

      stub_request(:put, %r{redmine\.example\.com/issues/100\.json})
        .to_return(status: 200, body: '{}')

      allow(Errmine::Notifier.instance).to receive(:generate_checksum).and_return('abcd1234')

      exception = sample_exception('Test error')
      Errmine.notify(exception)

      expect(WebMock).to have_requested(:put, %r{redmine\.example\.com/issues/100\.json})
    end

    it 'rate limits repeated errors' do
      stub_redmine_api

      exception = sample_exception('Repeated error')

      5.times { Errmine.notify(exception) }

      expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json}).once
    end

    it 'handles API failures gracefully' do
      stub_request(:get, %r{redmine\.example\.com/issues\.json})
        .to_return(status: 500, body: 'Internal Server Error')

      exception = sample_exception('API failure test')

      expect { Errmine.notify(exception) }.not_to raise_error
    end
  end

  describe 'Middleware integration' do
    let(:app) { ->(_env) { [200, {}, ['OK']] } }
    let(:middleware) { Errmine::Middleware.new(app) }

    before { stub_redmine_api }

    it 'allows successful requests to pass through' do
      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/test' }

      status, _headers, body = middleware.call(env)

      expect(status).to eq(200)
      expect(body).to eq(['OK'])
    end

    it 'notifies on exception and re-raises' do
      failing_app = ->(_env) { raise StandardError, 'Middleware test error' }
      middleware = Errmine::Middleware.new(failing_app)

      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/failing' }

      expect { middleware.call(env) }.to raise_error(StandardError, 'Middleware test error')
      expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json})
    end

    it 'includes request context in notification' do
      failing_app = ->(_env) { raise StandardError, 'Context test' }
      middleware = Errmine::Middleware.new(failing_app)

      env = {
        'REQUEST_METHOD' => 'POST',
        'PATH_INFO' => '/users/123',
        'REQUEST_URI' => '/users/123?foo=bar'
      }

      expect { middleware.call(env) }.to raise_error(StandardError)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?('/users/123') })
    end
  end

  describe 'thread safety' do
    before { stub_redmine_api }

    it 'handles concurrent notifications' do
      Errmine.configuration.cooldown = 0

      threads = 10.times.map do |i|
        Thread.new do
          exception = sample_exception("Thread #{i} error")
          Errmine.notify(exception)
        end
      end

      expect { threads.each(&:join) }.not_to raise_error
    end
  end
end
