# frozen_string_literal: true

RSpec.describe Errmine do
  describe '.configuration' do
    it 'returns a Configuration instance' do
      expect(described_class.configuration).to be_a(Errmine::Configuration)
    end

    it 'returns the same instance on multiple calls' do
      expect(described_class.configuration).to be(described_class.configuration)
    end
  end

  describe '.configure' do
    it 'yields the configuration' do
      described_class.configure do |config|
        expect(config).to be_a(Errmine::Configuration)
      end
    end

    it 'allows setting configuration values' do
      described_class.configure do |config|
        config.redmine_url = 'https://redmine.example.com'
        config.api_key = 'my-api-key'
        config.project_id = 'my-project'
        config.tracker_id = 2
        config.app_name = 'my-app'
        config.cooldown = 600
      end

      config = described_class.configuration
      expect(config.redmine_url).to eq('https://redmine.example.com')
      expect(config.api_key).to eq('my-api-key')
      expect(config.project_id).to eq('my-project')
      expect(config.tracker_id).to eq(2)
      expect(config.app_name).to eq('my-app')
      expect(config.cooldown).to eq(600)
    end
  end

  describe '.reset_configuration!' do
    it 'resets configuration to defaults' do
      described_class.configure do |config|
        config.redmine_url = 'https://custom.example.com'
        config.project_id = 'custom-project'
      end

      described_class.reset_configuration!

      expect(described_class.configuration.redmine_url).to be_nil
      expect(described_class.configuration.project_id).to eq('bug-tracker')
    end
  end

  describe '.notify' do
    context 'when not configured' do
      it 'returns nil without error' do
        exception = sample_exception
        expect(described_class.notify(exception)).to be_nil
      end
    end

    context 'when disabled' do
      before do
        configure_errmine
        described_class.configuration.enabled = false
      end

      it 'returns nil' do
        exception = sample_exception
        expect(described_class.notify(exception)).to be_nil
      end
    end

    context 'when configured' do
      before { configure_errmine }

      it 'delegates to Notifier' do
        stub_request(:get, /redmine\.example\.com/)
          .to_return(status: 200, body: '{"issues":[]}')
        stub_request(:post, /redmine\.example\.com/)
          .to_return(status: 201, body: '{"issue":{"id":1}}')

        exception = sample_exception
        result = described_class.notify(exception)
        expect(result).to be_a(Hash)
      end
    end

    context 'when notifier raises an error' do
      before { configure_errmine }

      it 'catches the error and returns nil' do
        allow(Errmine::Notifier.instance).to receive(:notify).and_raise(StandardError, 'Test error')

        exception = sample_exception
        expect { described_class.notify(exception) }.not_to raise_error
        expect(described_class.notify(exception)).to be_nil
      end
    end
  end

  describe '.create_issue' do
    context 'when not configured' do
      it 'returns nil without error' do
        expect(described_class.create_issue(subject: 'Test', description: 'Test')).to be_nil
      end
    end

    context 'when disabled' do
      before do
        configure_errmine
        described_class.configuration.enabled = false
      end

      it 'returns nil' do
        expect(described_class.create_issue(subject: 'Test', description: 'Test')).to be_nil
      end
    end

    context 'when configured' do
      before { configure_errmine }

      it 'delegates to Notifier' do
        stub_request(:post, /redmine\.example\.com/)
          .to_return(status: 201, body: '{"issue":{"id":1}}')

        result = described_class.create_issue(
          subject: 'Custom issue',
          description: 'Custom description'
        )

        expect(result).to be_a(Hash)
        expect(result['id']).to eq(1)
      end

      it 'passes options to Notifier' do
        stub_request(:post, /redmine\.example\.com/)
          .to_return(status: 201, body: '{"issue":{"id":1}}')

        described_class.create_issue(
          subject: 'Test',
          description: 'Test',
          tracker_id: 5,
          project_id: 'other'
        )

        expect(WebMock).to(have_requested(:post, /redmine\.example\.com/)
          .with do |req|
            body = JSON.parse(req.body)
            body['issue']['tracker_id'] == 5 && body['issue']['project_id'] == 'other'
          end)
      end
    end

    context 'when notifier raises an error' do
      before { configure_errmine }

      it 'catches the error and returns nil' do
        allow(Errmine::Notifier.instance).to receive(:create_custom_issue).and_raise(StandardError, 'Test error')

        expect { described_class.create_issue(subject: 'Test', description: 'Test') }.not_to raise_error
        expect(described_class.create_issue(subject: 'Test', description: 'Test')).to be_nil
      end
    end
  end

  describe Errmine::Configuration do
    describe '#initialize' do
      context 'with environment variables' do
        before do
          ENV['ERRMINE_REDMINE_URL'] = 'https://env.example.com'
          ENV['ERRMINE_API_KEY'] = 'env-key'
          ENV['ERRMINE_PROJECT'] = 'env-project'
          ENV['ERRMINE_APP_NAME'] = 'env-app'
        end

        after do
          ENV.delete('ERRMINE_REDMINE_URL')
          ENV.delete('ERRMINE_API_KEY')
          ENV.delete('ERRMINE_PROJECT')
          ENV.delete('ERRMINE_APP_NAME')
        end

        it 'reads from environment variables' do
          config = described_class.new

          expect(config.redmine_url).to eq('https://env.example.com')
          expect(config.api_key).to eq('env-key')
          expect(config.project_id).to eq('env-project')
          expect(config.app_name).to eq('env-app')
        end
      end

      context 'without environment variables' do
        it 'uses default values' do
          config = described_class.new

          expect(config.redmine_url).to be_nil
          expect(config.api_key).to be_nil
          expect(config.project_id).to eq('bug-tracker')
          expect(config.tracker_id).to eq(1)
          expect(config.app_name).to eq('unknown')
          expect(config.default_tags).to eq([])
          expect(config.enabled).to be(true)
          expect(config.cooldown).to eq(300)
        end
      end
    end

    describe '#default_tags' do
      it 'can be set to an array of strings' do
        config = described_class.new
        config.default_tags = %w[production app-errors]

        expect(config.default_tags).to eq(%w[production app-errors])
      end
    end

    describe '#valid?' do
      it 'returns false when redmine_url is nil' do
        config = described_class.new
        config.api_key = 'key'
        expect(config.valid?).to be(false)
      end

      it 'returns false when api_key is nil' do
        config = described_class.new
        config.redmine_url = 'https://example.com'
        expect(config.valid?).to be(false)
      end

      it 'returns false when redmine_url is empty' do
        config = described_class.new
        config.redmine_url = ''
        config.api_key = 'key'
        expect(config.valid?).to be(false)
      end

      it 'returns true when both redmine_url and api_key are set' do
        config = described_class.new
        config.redmine_url = 'https://example.com'
        config.api_key = 'key'
        expect(config.valid?).to be(true)
      end
    end
  end
end
