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
end
