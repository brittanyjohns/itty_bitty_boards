require "rails_helper"

RSpec.describe MailchimpTrialWrapJob, type: :job do
  subject(:job) { described_class.new }

  let(:user) { create(:user) }
  let(:mailchimp) { instance_double(MailchimpService) }

  before { allow(MailchimpService).to receive(:new).and_return(mailchimp) }

  describe "#perform" do
    context "when journeys are enabled and trial_wrap is configured" do
      before do
        allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
        allow(MailchimpClient).to receive(:journey).with("trial_wrap")
          .and_return(journey_id: 50, step_id: 60)
        allow(mailchimp).to receive(:update_merge_fields)
        allow(mailchimp).to receive(:trigger_journey)
      end

      it "syncs personalization merge fields (counts + formatted trial end), then triggers" do
        create_list(:board, 2, user: user)
        create(:child_account, owner_id: user.id)
        epoch = Time.utc(2026, 6, 20, 12, 0, 0).to_i

        expect(mailchimp).to receive(:update_merge_fields).with(
          user,
          { "TRIAL_END" => "June 20", "BOARDS" => "2", "COMMS" => "1" },
        ).ordered
        expect(mailchimp).to receive(:trigger_journey).with(
          user, journey_id: 50, step_id: 60
        ).ordered

        job.perform(user.id, epoch)
      end

      it "falls back to 'soon' when no trial-end date is given" do
        expect(mailchimp).to receive(:update_merge_fields).with(
          user, hash_including("TRIAL_END" => "soon")
        )
        job.perform(user.id, nil)
      end
    end

    it "skips (no merge-field sync, no trigger) when journeys are disabled" do
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(false)
      expect(mailchimp).not_to receive(:update_merge_fields)
      expect(mailchimp).not_to receive(:trigger_journey)

      job.perform(user.id, nil)
    end

    context "for a partner pilot" do
      let(:user) { create(:user, plan_type: "partner_pro", role: "partner") }

      it "triggers the partner_pilot_wrap journey instead of the generic one" do
        allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
        allow(MailchimpClient).to receive(:journey).with("partner_pilot_wrap")
          .and_return(journey_id: 70, step_id: 80)
        allow(mailchimp).to receive(:update_merge_fields)

        expect(MailchimpClient).not_to receive(:journey).with("trial_wrap")
        expect(mailchimp).to receive(:trigger_journey).with(
          user, journey_id: 70, step_id: 80
        )

        job.perform(user.id, nil)
      end
    end

    it "skips when the trial_wrap journey isn't configured" do
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
      allow(MailchimpClient).to receive(:journey).with("trial_wrap").and_return(nil)
      expect(mailchimp).not_to receive(:trigger_journey)

      job.perform(user.id, nil)
    end

    it "no-ops for an unknown user id" do
      allow(MailchimpClient).to receive(:journeys_enabled?).and_return(true)
      expect(mailchimp).not_to receive(:trigger_journey)

      job.perform(-1, nil)
    end
  end
end
