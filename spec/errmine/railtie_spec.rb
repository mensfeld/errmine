# frozen_string_literal: true

# Minimal stand-in for Rails, so the Railtie loads without a Rails app
module Rails
  def self.version = nil
  def self.error = nil

  class Railtie
    Config = Struct.new(:after_initialize_blocks) do
      def after_initialize(&block) = after_initialize_blocks << block
    end

    class << self
      def initializers = @initializers ||= []
      def initializer(_name, &block) = initializers << block
      def config = @config ||= Config.new([])
    end
  end
end

require 'errmine/railtie'

RSpec.describe Errmine::Railtie do
  describe 'after_initialize' do
    it 'adds the String, Symbol and Regexp entries of the app filter_parameters' do
      app = double(config: double(filter_parameters: ['pin', :iban, /\Acode\z/, ->(_k, _v) {}, 'token']))

      described_class.config.after_initialize_blocks.each { |block| block.call(app) }

      expect(Errmine.configuration.filter_parameters).to eq(
        %w[passw email secret token _key crypt salt certificate otp ssn cvv cvc] + ['pin', :iban, /\Acode\z/]
      )
    end
  end

  describe 'initializer' do
    let(:error_reporter) { double(subscribe: nil) }

    before do
      allow(Rails).to receive_messages(version: version, error: error_reporter)
    end

    context 'with Rails 7+' do
      let(:version) { '7.1.0' }

      it 'subscribes an ErrorSubscriber' do
        described_class.initializers.each { |block| block.call(nil) }

        expect(error_reporter).to have_received(:subscribe).with(instance_of(described_class::ErrorSubscriber))
      end
    end

    context 'with Rails older than 7' do
      let(:version) { '6.1.0' }

      it 'does not subscribe' do
        described_class.initializers.each { |block| block.call(nil) }

        expect(error_reporter).not_to have_received(:subscribe)
      end
    end
  end

  describe 'ErrorSubscriber#report' do
    let(:subscriber) { described_class::ErrorSubscriber.new }
    let(:error) { sample_exception }

    before { allow(Errmine).to receive(:notify) }

    it 'ignores handled errors' do
      subscriber.report(error, handled: true, severity: :warning)

      expect(Errmine).not_to have_received(:notify)
    end

    it 'passes url, user, source and severity' do
      subscriber.report(
        error, handled: false, severity: :error, context: { url: '/x', user: 42 }, source: 'application'
      )

      expect(Errmine).to have_received(:notify)
        .with(error, { url: '/x', user: '42', source: 'application', severity: :error })
    end

    it 'passes only what is present' do
      subscriber.report(error, handled: false, severity: nil)

      expect(Errmine).to have_received(:notify).with(error, {})
    end

    it 'warns instead of raising when notify fails' do
      allow(Errmine).to receive(:notify).and_raise(StandardError, 'boom')
      allow(subscriber).to receive(:warn)

      expect { subscriber.report(error, handled: false, severity: :error) }.not_to raise_error
      expect(subscriber).to have_received(:warn).with('[Errmine] Error subscriber failed: boom')
    end
  end
end
