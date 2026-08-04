require "rails_helper"

RSpec.describe MailchimpClient do
  describe ".journey" do
    before { allow(ENV).to receive(:[]).and_call_original }

    it "resolves a configured key to integer journey_id/step_id from ENV" do
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEY_WELCOME_ID").and_return("123")
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEY_WELCOME_STEP").and_return("456")

      expect(MailchimpClient.journey(:welcome)).to eq(journey_id: 123, step_id: 456)
    end

    it "accepts string keys too" do
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEY_WELCOME_ID").and_return("123")
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEY_WELCOME_STEP").and_return("456")

      expect(MailchimpClient.journey("welcome")).to eq(journey_id: 123, step_id: 456)
    end

    it "returns nil when the key is not configured" do
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEY_UNSET_ID").and_return(nil)
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEY_UNSET_STEP").and_return(nil)

      expect(MailchimpClient.journey(:unset)).to be_nil
    end
  end

  describe ".journeys_enabled?" do
    before { allow(ENV).to receive(:[]).and_call_original }

    it "is enabled when the explicit flag is set" do
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEYS_ENABLED").and_return("true")

      expect(MailchimpClient.journeys_enabled?).to be true
    end

    it "is enabled in production when not staging" do
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEYS_ENABLED").and_return(nil)
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(AppEnv).to receive(:staging?).and_return(false)

      expect(MailchimpClient.journeys_enabled?).to be true
    end

    it "is disabled on staging even in the production rails env" do
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEYS_ENABLED").and_return(nil)
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(AppEnv).to receive(:staging?).and_return(true)

      expect(MailchimpClient.journeys_enabled?).to be false
    end

    it "is disabled in dev/test without the flag" do
      allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEYS_ENABLED").and_return(nil)

      expect(MailchimpClient.journeys_enabled?).to be false
    end
  end

  # The nudge crons gate their permanent per-user "already nudged" flags on
  # this, so an unconfigured journey must read as not-deliverable rather than
  # burning the backlog.
  describe ".journey_deliverable?" do
    it "is true only when journeys are enabled AND the key is configured" do
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
      allow(MailchimpClient).to receive(:journey).with("first_board_nudge")
        .and_return({ journey_id: 1, step_id: 2 })

      expect(MailchimpClient.journey_deliverable?("first_board_nudge")).to be true
    end

    it "is false when the journey's ENV pair is missing" do
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
      allow(MailchimpClient).to receive(:journey).with("first_board_nudge").and_return(nil)

      expect(MailchimpClient.journey_deliverable?("first_board_nudge")).to be false
    end

    it "is false when journeys are disabled for the environment" do
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(false)

      expect(MailchimpClient.journey_deliverable?("first_board_nudge")).to be false
    end
  end
end
