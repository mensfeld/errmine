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

  describe 'query parameter filtering' do
    let(:middleware) { described_class.new(failing_app) }

    before { stub_redmine_api }

    def report(uri)
      env = { 'REQUEST_METHOD' => 'GET', 'REQUEST_URI' => uri }
      expect { middleware.call(env) }.to raise_error(StandardError)
    end

    def expect_reported(text)
      expect(WebMock).to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?(text) })
    end

    def expect_not_reported(text)
      expect(WebMock).not_to(have_requested(:post, %r{redmine\.example\.com/issues\.json})
        .with { |req| req.body.include?(text) })
    end

    it 'filters sensitive query parameter values with the default list' do
      report('/password/edit?reset_password_token=S3CR3T&page=2&user%5Bpassword%5D=hunter2&api_key=K')

      expect_reported(
        '**URL:** /password/edit?reset_password_token=[FILTERED]&page=2&' \
        'user%5Bpassword%5D=[FILTERED]&api_key=[FILTERED]'
      )
      expect_not_reported('S3CR3T')
      expect_not_reported('hunter2')
      expect_not_reported('api_key=K')
    end

    it 'matches String and Symbol filters case-insensitively' do
      Errmine.configuration.filter_parameters = [:pin, 'Session']
      report('/x?PIN=1234&user_session_id=abc&other=ok')

      expect_reported('**URL:** /x?PIN=[FILTERED]&user_session_id=[FILTERED]&other=ok')
    end

    it 'matches Regexp filters' do
      Errmine.configuration.filter_parameters = [/\Acode\z/]
      report('/oauth/callback?code=ABC&state=xyz&zipcode=1')

      expect_reported('**URL:** /oauth/callback?code=[FILTERED]&state=xyz&zipcode=1')
    end

    it 'filters a sensitive key without a value' do
      report('/x?token&a=1')

      expect_reported('**URL:** /x?token=[FILTERED]&a=1')
    end

    it 'filters the whole query when a key cannot be decoded' do
      report('/x?%zztoken=SECRET&a=1')

      expect_reported('**URL:** /x?[FILTERED]')
      expect_not_reported('SECRET')
    end

    it 'keeps a URL without a query unchanged' do
      report('/users/1')

      expect_reported('**URL:** /users/1')
    end
  end
end
