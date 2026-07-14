require "rails_helper"

RSpec.describe PartnerPilotEndingJob, type: :job do
  subject(:job) { described_class.new }

  def create_partner(plan_expires_at:, settings: nil)
    user = FactoryBot.create(:user, plan_type: "partner_pro", role: "partner")
    user.update_columns(plan_expires_at: plan_expires_at)
    user.update!(settings: settings) if settings
    user.reload
  end

  def partner_reminder_mails
    ActionMailer::Base.deliveries.select { |m| m.subject.match?(/pilot is wrapping up/i) }
  end

  def admin_digest
    ActionMailer::Base.deliveries.find { |m| m.subject.include?("Partner pilots") }
  end

  before { ActionMailer::Base.deliveries.clear }

  describe "#perform" do
    context "a partner ending within the lead window" do
      it "flags them for the digest without emailing the partner (Stripe/Mailchimp own the nudge)" do
        user = create_partner(plan_expires_at: 5.days.from_now)

        expect { job.perform }
          .to change { user.reload.settings["partner_pilot_ending_notified"] }.to(true)
        expect(partner_reminder_mails).to be_empty
      end

      it "emails the partner when the legacy reminder is explicitly re-enabled" do
        create_partner(plan_expires_at: 5.days.from_now)

        climate = ENV["PARTNER_PILOT_LEGACY_REMINDER"]
        ENV["PARTNER_PILOT_LEGACY_REMINDER"] = "true"
        begin
          job.perform
        ensure
          ENV["PARTNER_PILOT_LEGACY_REMINDER"] = climate
        end

        expect(partner_reminder_mails).not_to be_empty
      end

      it "does not re-flag an already-flagged partner" do
        user = create_partner(plan_expires_at: 5.days.from_now,
                              settings: { "partner_pilot_ending_notified" => true })

        expect { job.perform }
          .not_to change { user.reload.settings["partner_pilot_ending_notified"] }
      end

      it "does not change plan_type (no downgrade)" do
        user = create_partner(plan_expires_at: 5.days.from_now)

        expect { job.perform }.not_to change { user.reload.plan_type }
      end
    end

    context "a partner past expiry" do
      it "flags the pilot expired without downgrading" do
        user = create_partner(plan_expires_at: 2.days.ago)

        expect { job.perform }
          .to change { user.reload.settings["partner_pilot_expired"] }.to(true)
        expect(user.reload.plan_type).to eq("partner_pro")
        expect(user.settings["partner_pilot_expired_at"]).to be_present
      end

      it "does not send the ending-soon email to an expired partner" do
        create_partner(plan_expires_at: 2.days.ago)

        job.perform

        expect(partner_reminder_mails).to be_empty
      end

      it "does not re-flag an already-flagged partner" do
        user = create_partner(
          plan_expires_at: 2.days.ago,
          settings: { "partner_pilot_expired" => true, "partner_pilot_expired_at" => 10.days.ago.iso8601 },
        )
        original = user.settings["partner_pilot_expired_at"]

        job.perform

        expect(user.reload.settings["partner_pilot_expired_at"]).to eq(original)
      end
    end

    context "the admin digest" do
      it "is sent once with a summary count when there are candidates" do
        create_partner(plan_expires_at: 3.days.from_now)
        create_partner(plan_expires_at: 1.day.ago)

        job.perform

        expect(admin_digest).to be_present
        expect(admin_digest.subject).to eq("Partner pilots: 1 ended, 1 ending soon")
      end

      it "is not sent when nothing is ending or expired" do
        create_partner(plan_expires_at: 60.days.from_now)

        job.perform

        expect(admin_digest).to be_nil
      end
    end

    context "partners outside the window" do
      it "ignores a partner with no plan_expires_at" do
        user = create_partner(plan_expires_at: nil)

        job.perform

        expect(user.reload.settings["partner_pilot_ending_notified"]).to be_nil
        expect(user.settings["partner_pilot_expired"]).to be_nil
      end

      it "ignores a partner expiring beyond the lead window" do
        user = create_partner(plan_expires_at: 45.days.from_now)

        job.perform

        expect(user.reload.settings["partner_pilot_ending_notified"]).to be_nil
        expect(partner_reminder_mails).to be_empty
      end
    end

    context "with a custom PARTNER_PILOT_REMINDER_LEAD_DAYS" do
      it "reminds partners inside the widened window" do
        user = create_partner(plan_expires_at: 20.days.from_now)

        climate = ENV["PARTNER_PILOT_REMINDER_LEAD_DAYS"]
        ENV["PARTNER_PILOT_REMINDER_LEAD_DAYS"] = "30"
        begin
          job.perform
        ensure
          ENV["PARTNER_PILOT_REMINDER_LEAD_DAYS"] = climate
        end

        expect(user.reload.settings["partner_pilot_ending_notified"]).to be(true)
      end
    end
  end
end
