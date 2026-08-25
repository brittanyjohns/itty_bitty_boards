# frozen_string_literal: true

require "rails_helper"

RSpec.describe PosthogService do
  let(:user) do
    FactoryBot.build_stubbed(:user, id: 4242, plan_type: "pro",
                                    email: "parent@example.com", name: "Parent Example")
  end
  let(:identity) { { plan: "pro", email: "parent@example.com", name: "Parent Example" } }
  let(:client) { instance_double("PostHog::Client") }

  describe ".capture_for_user" do
    context "when capture is enabled" do
      before do
        allow(PosthogClient).to receive(:enabled?).and_return(true)
        allow(PosthogClient).to receive(:client).and_return(client)
      end

      it "captures with distinct_id = user.id.to_s (matches the frontend identify contract)" do
        expect(client).to receive(:capture).with(
          hash_including(distinct_id: "4242", event: "subscription_started"),
        )
        described_class.capture_for_user(user, "subscription_started", properties: { plan: "pro" })
      end

      it "passes through event properties and defaults $set to plan + email + name" do
        expect(client).to receive(:capture).with(
          distinct_id: "4242",
          event: "subscription_started",
          properties: {
            plan: "pro",
            billing_interval: "monthly",
            "$set" => identity,
            "$geoip_disable" => true,
          },
        )
        described_class.capture_for_user(
          user,
          "subscription_started",
          properties: { plan: "pro", billing_interval: "monthly" },
        )
      end

      it "disables geoip so the app server's IP can't overwrite the person's location" do
        expect(client).to receive(:capture).with(
          hash_including(properties: hash_including("$geoip_disable" => true)),
        )
        described_class.capture_for_user(user, "user_signed_in", properties: {})
      end

      it "merges an explicit :set OVER the defaults rather than replacing them" do
        expect(client).to receive(:capture).with(
          hash_including(
            properties: hash_including(
              "$set" => identity.merge(plan: "free"),
            ),
          ),
        )
        described_class.capture_for_user(
          user,
          "subscription_cancelled",
          properties: { plan: "pro" },
          set: { plan: "free" },
        )
      end

      it "drops nil identity properties (a user with no name)" do
        nameless = FactoryBot.build_stubbed(:user, id: 7, plan_type: "free",
                                                   email: "no-name@example.com", name: nil)
        expect(client).to receive(:capture).with(
          hash_including(
            properties: hash_including(
              "$set" => { plan: "free", email: "no-name@example.com" },
            ),
          ),
        )
        described_class.capture_for_user(nameless, "user_signed_in", properties: {})
      end

      it "drops nil properties so they don't surface as empty PostHog props" do
        expect(client).to receive(:capture).with(
          hash_including(
            properties: {
              plan: "pro",
              "$set" => identity,
              "$geoip_disable" => true,
            },
          ),
        )
        described_class.capture_for_user(
          user,
          "subscription_cancelled",
          properties: { plan: "pro", reason: nil },
        )
      end

      it "never raises when the client errors (analytics must not break the webhook)" do
        allow(client).to receive(:capture).and_raise(StandardError, "boom")
        expect {
          described_class.capture_for_user(user, "subscription_started", properties: {})
        }.not_to raise_error
      end

      it "no-ops without a user" do
        expect(client).not_to receive(:capture)
        described_class.capture_for_user(nil, "subscription_started")
      end
    end

    context "when capture is disabled" do
      before { allow(PosthogClient).to receive(:enabled?).and_return(false) }

      it "does not build a client or capture" do
        expect(PosthogClient).not_to receive(:client)
        described_class.capture_for_user(user, "subscription_started", properties: {})
      end
    end
  end
end

RSpec.describe PosthogClient do
  describe ".enabled?" do
    it "is false without an API key, even with the override on" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POSTHOG_API_KEY").and_return(nil)
      allow(ENV).to receive(:[]).with("POSTHOG_CAPTURE_ENABLED").and_return("true")
      expect(described_class.enabled?).to be(false)
    end

    it "is true when POSTHOG_CAPTURE_ENABLED=true and a key is present (dev/staging opt-in)" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POSTHOG_API_KEY").and_return("phc_test")
      allow(ENV).to receive(:[]).with("POSTHOG_CAPTURE_ENABLED").and_return("true")
      expect(described_class.enabled?).to be(true)
    end

    it "is false in the test environment by default (no override)" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("POSTHOG_API_KEY").and_return("phc_test")
      allow(ENV).to receive(:[]).with("POSTHOG_CAPTURE_ENABLED").and_return(nil)
      expect(described_class.enabled?).to be(false)
    end
  end
end
