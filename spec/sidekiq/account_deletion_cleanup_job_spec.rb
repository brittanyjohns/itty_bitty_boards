require "rails_helper"

RSpec.describe AccountDeletionCleanupJob, type: :sidekiq do
  let(:user) { FactoryBot.create(:user, email: "doomed@example.com") }
  let(:mailchimp) { instance_double(MailchimpService) }

  before do
    allow(MailchimpService).to receive(:new).and_return(mailchimp)
    allow(mailchimp).to receive(:archive_subscriber)
    stub_const("ENV", ENV.to_h.merge("MAILCHIMP_API_KEY" => "test-key", "MAILCHIMP_AUDIENCE_ID" => "aud_123"))
  end

  describe "#perform" do
    it "archives the Mailchimp subscriber with the original email" do
      expect(mailchimp).to receive(:archive_subscriber) do |stub_user, reason:|
        expect(stub_user.email).to eq("doomed@example.com")
        expect(stub_user.id).to eq(user.id)
        expect(reason).to eq("user_requested")
      end

      described_class.new.perform(user.id, "doomed@example.com", "user_requested")
    end

    it "captures an account_deleted event in PostHog when enabled" do
      posthog_client = double("PostHog::Client")
      allow(PosthogClient).to receive(:enabled?).and_return(true)
      allow(PosthogClient).to receive(:client).and_return(posthog_client)

      expect(posthog_client).to receive(:capture).with(
        distinct_id: user.id.to_s,
        event: "account_deleted",
        properties: hash_including("reason" => "user_requested"),
      )

      described_class.new.perform(user.id, "doomed@example.com", "user_requested")
    end

    it "skips PostHog when disabled" do
      allow(PosthogClient).to receive(:enabled?).and_return(false)

      expect { described_class.new.perform(user.id, "doomed@example.com") }.not_to raise_error
    end

    it "nullifies analytics_events for the user" do
      AnalyticsEvent.track(:user_signed_up, user_id: user.id)
      AnalyticsEvent.track(:board_generated, user_id: user.id)

      described_class.new.perform(user.id, "doomed@example.com")

      expect(AnalyticsEvent.where(user_id: user.id).count).to eq(0)
      expect(AnalyticsEvent.where(user_id: nil).count).to be >= 2
    end

    it "calls RevenueCat delete when API key is set" do
      stub_const("ENV", ENV.to_h.merge(
        "REVENUECAT_REST_API_KEY" => "rc_test_key",
        "MAILCHIMP_API_KEY" => "test-key",
        "MAILCHIMP_AUDIENCE_ID" => "aud_123",
      ))

      stubs = Faraday::Adapter::Test::Stubs.new
      stubs.delete("/v1/subscribers/#{user.id}") { [200, {}, "{}"] }
      test_conn = Faraday.new { |b| b.adapter :test, stubs }
      allow(Faraday).to receive(:new).and_return(test_conn)

      described_class.new.perform(user.id, "doomed@example.com")

      stubs.verify_stubbed_calls
    end

    it "skips RevenueCat when API key is blank" do
      stub_const("ENV", ENV.to_h.merge(
        "REVENUECAT_REST_API_KEY" => nil,
        "MAILCHIMP_API_KEY" => "test-key",
        "MAILCHIMP_AUDIENCE_ID" => "aud_123",
      ))

      expect { described_class.new.perform(user.id, "doomed@example.com") }.not_to raise_error
    end

    it "skips Mailchimp when API key is blank" do
      stub_const("ENV", ENV.to_h.merge("MAILCHIMP_API_KEY" => nil))

      expect(mailchimp).not_to receive(:archive_subscriber)

      described_class.new.perform(user.id, "doomed@example.com")
    end

    it "does not raise when any third-party cleanup fails" do
      allow(mailchimp).to receive(:archive_subscriber).and_raise(StandardError, "Mailchimp down")
      allow(PosthogClient).to receive(:enabled?).and_return(true)
      allow(PosthogClient).to receive(:client).and_return(nil)

      expect { described_class.new.perform(user.id, "doomed@example.com") }.not_to raise_error
    end
  end
end
