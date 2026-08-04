require "rails_helper"

RSpec.describe MailchimpEventJob, type: :sidekiq do
  let(:user) { FactoryBot.create(:user) }
  let(:mailchimp) { instance_double(MailchimpService) }

  before { allow(MailchimpService).to receive(:new).and_return(mailchimp) }

  describe "#perform with 'journey'" do
    context "when journeys are enabled and the key is configured" do
      before do
        allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
        allow(MailchimpClient).to receive(:journey).with("welcome")
          .and_return(journey_id: 10, step_id: 20)
      end

      it "dispatches to trigger_journey with the resolved ids" do
        expect(mailchimp).to receive(:trigger_journey).with(user, journey_id: 10, step_id: 20)

        described_class.new.perform(user.id, "journey", { "journey_key" => "welcome" })
      end
    end

    it "skips (no trigger) when journeys are disabled" do
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(false)
      expect(mailchimp).not_to receive(:trigger_journey)

      described_class.new.perform(user.id, "journey", { "journey_key" => "welcome" })
    end

    context "with a demo/internal account" do
      before do
        allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
        allow(MailchimpClient).to receive(:journey).with("welcome")
          .and_return(journey_id: 10, step_id: 20)
      end

      it "skips a bhannajohns+ alias" do
        demo = FactoryBot.create(:user, email: "bhannajohns+test@gmail.com")
        expect(mailchimp).not_to receive(:trigger_journey)

        described_class.new.perform(demo.id, "journey", { "journey_key" => "welcome" })
      end

      it "skips an @speakanyway.com address" do
        demo = FactoryBot.create(:user, email: "someone@speakanyway.com")
        expect(mailchimp).not_to receive(:trigger_journey)

        described_class.new.perform(demo.id, "journey", { "journey_key" => "welcome" })
      end

      it "still triggers when MAILCHIMP_JOURNEYS_ALLOW_DEMO=true (end-to-end testing)" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEYS_ALLOW_DEMO").and_return("true")
        demo = FactoryBot.create(:user, email: "bhannajohns+test@gmail.com")

        expect(mailchimp).to receive(:trigger_journey).with(demo, journey_id: 10, step_id: 20)

        described_class.new.perform(demo.id, "journey", { "journey_key" => "welcome" })
      end

      it "does not gate CRM sync — demo contacts stay in the audience" do
        demo = FactoryBot.create(:user, email: "bhannajohns+test@gmail.com")
        expect(mailchimp).to receive(:record_new_subscriber).with(demo, tags: [])

        described_class.new.perform(demo.id, "sign_up")
      end
    end

    it "skips when the journey key is not configured" do
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
      allow(MailchimpClient).to receive(:journey).with("mystery").and_return(nil)
      expect(mailchimp).not_to receive(:trigger_journey)

      described_class.new.perform(user.id, "journey", { "journey_key" => "mystery" })
    end
  end
end
