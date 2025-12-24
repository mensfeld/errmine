# frozen_string_literal: true

RSpec.describe Errmine::Middleware do
  let(:success_app) { ->(_env) { [200, {}, ['OK']] } }
  let(:failing_app) { ->(_env) { raise StandardError, 'Test error' } }
  let(:middleware) { described_class.new(success_app) }

  before { configure_errmine }

  def stub_redmine_api
    stub_request(:get, %r{redmine\.example\.com/issues\.json})
      .to_return(status: 200, body: '{"issues":[]}')

    stub_request(:post, %r{redmine\.example\.com/issues\.json})
      .to_return(status: 201, body: '{"issue":{"id":1}}')
  end

  describe '#initialize' do
    it 'stores the app' do
      middleware = described_class.new(success_app)
      expect(middleware.instance_variable_get(:@app)).to eq(success_app)
    end
  end

  describe '#call' do
    context 'when request succeeds' do
      it 'returns the response' do
        env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/' }
        status, headers, body = middleware.call(env)

        expect(status).to eq(200)
        expect(headers).to eq({})
        expect(body).to eq(['OK'])
      end
    end

    context 'when request raises exception' do
      let(:middleware) { described_class.new(failing_app) }

      before { stub_redmine_api }

      it 're-raises the exception' do
        env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/' }

        expect { middleware.call(env) }.to raise_error(StandardError, 'Test error')
      end

      it 'notifies Errmine before re-raising' do
        env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/' }

        expect { middleware.call(env) }.to raise_error(StandardError)
        expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json})
      end
    end

    context 'when notification itself fails' do
      let(:middleware) { described_class.new(failing_app) }

      it 'still re-raises the original exception' do
        allow(Errmine).to receive(:notify).and_raise(StandardError, 'Notification failed')

        env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/' }

        expect { middleware.call(env) }.to raise_error(StandardError, 'Test error')
      end
    end
  end

  describe 'context building' do
    let(:middleware) { described_class.new(failing_app) }

    before { stub_redmine_api }

    it 'includes REQUEST_URI when present' do
      env = { 'REQUEST_METHOD' => 'GET', 'REQUEST_URI' => '/full/uri?query=1' }

      expect { middleware.call(env) }.to raise_error(StandardError)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?('/full/uri?query=1') })
    end

    it 'falls back to PATH_INFO when REQUEST_URI is absent' do
      env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/path/only' }

      expect { middleware.call(env) }.to raise_error(StandardError)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?('/path/only') })
    end

    it 'includes request method' do
      env = { 'REQUEST_METHOD' => 'POST', 'PATH_INFO' => '/' }

      expect { middleware.call(env) }.to raise_error(StandardError)

      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?('POST') })
    end

    context 'with warden user' do
      it 'includes user email when user responds to email' do
        user = double(email: 'test@example.com')
        warden = double(user: user)
        env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/', 'warden' => warden }

        expect { middleware.call(env) }.to raise_error(StandardError)

        expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
          .with { |req| req.body.include?('test@example.com') })
      end

      it 'uses to_s when user does not respond to email' do
        user = double(to_s: 'User#123')
        allow(user).to receive(:respond_to?).with(:email).and_return(false)
        warden = double(user: user)
        env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/', 'warden' => warden }

        expect { middleware.call(env) }.to raise_error(StandardError)

        expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
          .with { |req| req.body.include?('User#123') })
      end

      it 'handles nil warden user' do
        warden = double(user: nil)
        env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/', 'warden' => warden }

        expect { middleware.call(env) }.to raise_error(StandardError)

        # Should not include user in context
        expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
          .with { |req| !req.body.include?('user') || req.body.include?('User:') == false })
      end
    end

    context 'without warden' do
      it 'works without user context' do
        env = { 'REQUEST_METHOD' => 'GET', 'PATH_INFO' => '/' }

        expect { middleware.call(env) }.to raise_error(StandardError)
        expect(WebMock).to have_requested(:post, %r{redmine\.example\.com/issues\.json})
      end
    end
  end
end
