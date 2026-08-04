require "rails_helper"

RSpec.describe MailchimpEventJob, type: :sidekiq do
  let(:user) { FactoryBot.create(:user) }
  let(:mailchimp) { instance_double(MailchimpService) }

  before { allow(MailchimpService).to receive(:new).and_return(mailchimp) }

  # Rails.cache is :null_store in test, so the quiet-period throttle would
  # never see its own writes without a real store here.
  let(:cache) { ActiveSupport::Cache::MemoryStore.new }
  before { allow(Rails).to receive(:cache).and_return(cache) }

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

    # Journeys are triggered from unrelated seams that can coincide (welcome at
    # email_signup then subscription_started minutes later; the 04:00 and 04:30
    # nudge crons), and no caller knows what else the user is about to get.
    context "the back-to-back quiet period" do
      before do
        allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
        allow(MailchimpClient).to receive(:journey).and_return(journey_id: 10, step_id: 20)
        MailchimpEventJob.clear
      end

      it "sends the first journey and starts the quiet period" do
        expect(mailchimp).to receive(:trigger_journey).once.and_return(:ok)

        described_class.new.perform(user.id, "journey", { "journey_key" => "welcome" })

        expect(cache.read("mailchimp:journey:last_sent:#{user.id}")).to be_present
      end

      it "defers a second journey instead of sending it back to back" do
        allow(mailchimp).to receive(:trigger_journey).and_return(:ok)
        described_class.new.perform(user.id, "journey", { "journey_key" => "welcome" })

        expect(mailchimp).not_to receive(:trigger_journey)
        expect {
          described_class.new.perform(user.id, "journey", { "journey_key" => "subscription_started" })
        }.to change(MailchimpEventJob.jobs, :size).by(1)

        deferred = MailchimpEventJob.jobs.last
        expect(deferred["args"]).to eq([user.id, "journey", { "journey_key" => "subscription_started", "defers" => 1 }])
        expect(deferred["at"]).to be > Time.current.to_f
      end

      it "sends once the quiet period has passed" do
        allow(mailchimp).to receive(:trigger_journey).and_return(:ok)
        cache.write("mailchimp:journey:last_sent:#{user.id}", 5.hours.ago.to_i)

        expect(mailchimp).to receive(:trigger_journey).and_return(:ok)
        described_class.new.perform(user.id, "journey", { "journey_key" => "win_back" })
      end

      it "does not start the quiet period when the trigger failed" do
        allow(mailchimp).to receive(:trigger_journey).and_return(nil)

        described_class.new.perform(user.id, "journey", { "journey_key" => "welcome" })

        expect(cache.read("mailchimp:journey:last_sent:#{user.id}")).to be_nil
      end

      it "drops rather than deferring forever past MAX_DEFERS" do
        allow(mailchimp).to receive(:trigger_journey).and_return(:ok)
        cache.write("mailchimp:journey:last_sent:#{user.id}", Time.current.to_i)

        expect(mailchimp).not_to receive(:trigger_journey)
        expect(Rails.logger).to receive(:warn).with(/Dropping journey 'win_back'/)

        expect {
          described_class.new.perform(user.id, "journey", { "journey_key" => "win_back", "defers" => 3 })
        }.not_to change(MailchimpEventJob.jobs, :size)
      end

      it "honors MAILCHIMP_JOURNEY_MIN_GAP_HOURS" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("MAILCHIMP_JOURNEY_MIN_GAP_HOURS").and_return("1")
        cache.write("mailchimp:journey:last_sent:#{user.id}", 2.hours.ago.to_i)

        expect(mailchimp).to receive(:trigger_journey).and_return(:ok)
        described_class.new.perform(user.id, "journey", { "journey_key" => "win_back" })
      end

      it "throttles per user, not globally" do
        other = FactoryBot.create(:user)
        allow(mailchimp).to receive(:trigger_journey).and_return(:ok)
        described_class.new.perform(user.id, "journey", { "journey_key" => "welcome" })

        expect(mailchimp).to receive(:trigger_journey).with(other, any_args).and_return(:ok)
        described_class.new.perform(other.id, "journey", { "journey_key" => "welcome" })
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
