require "rails_helper"

RSpec.describe PlanExpiryJob, type: :sidekiq do
  def mailer_double
    double(deliver_later: true)
  end

  describe "renewal-notice pass (T-60)" do
    it "sends the renewal offer once for a license within the lead window and flags it" do
      user = FactoryBot.create(:user, plan_type: "pro_5yr")
      user.update_columns(plan_expires_at: 30.days.from_now)

      expect(UserMailer).to receive(:license_renewal_offer_email).with(user).once.and_return(mailer_double)

      described_class.new.perform
      expect(user.reload.settings["renewal_notice_sent_at"]).to be_present

      # Rerun: already flagged, no second send.
      expect(UserMailer).not_to receive(:license_renewal_offer_email)
      described_class.new.perform
    end

    it "does not send a renewal notice for a license beyond the lead window" do
      user = FactoryBot.create(:user, plan_type: "basic_5yr")
      user.update_columns(plan_expires_at: 200.days.from_now)

      expect(UserMailer).not_to receive(:license_renewal_offer_email)
      described_class.new.perform
      expect(user.reload.settings["renewal_notice_sent_at"]).to be_nil
    end
  end

  describe "expiry pass" do
    it "downgrades an expired basic_5yr license to free, retains data, emails, idempotently" do
      user = FactoryBot.create(:user, plan_type: "basic_5yr")
      user.update_columns(plan_expires_at: 1.day.ago)
      board_a = FactoryBot.create(:board, user: user)
      board_b = FactoryBot.create(:board, user: user)

      expect(UserMailer).to receive(:license_ended_email).with(user).once.and_return(mailer_double)

      described_class.new.perform

      user.reload
      expect(user.plan_type).to eq("free")
      expect(user.paid_plan?).to be(false)
      # Downgrades retain, never delete.
      expect(Board.where(id: [board_a.id, board_b.id]).count).to eq(2)
      # Free credit allowance granted on downgrade.
      expect(user.plan_credits_balance).to eq(CreditService.monthly_credits_for("free"))

      # Rerun is a no-op: user is now free, out of ENFORCED_PLAN_TYPES.
      expect(UserMailer).not_to receive(:license_ended_email)
      expect { described_class.new.perform }.not_to change { user.reload.plan_type }
    end
  end

  describe "scope" do
    it "ignores partner_pro, clinician, and free users" do
      partner = FactoryBot.create(:user, plan_type: "partner_pro", role: "partner")
      partner.update_columns(plan_expires_at: 1.day.ago)
      clinician = FactoryBot.create(:user, plan_type: "clinician")
      clinician.update_columns(plan_expires_at: 1.day.ago)
      free = FactoryBot.create(:user, plan_type: "free")

      expect(UserMailer).not_to receive(:license_ended_email)
      expect(UserMailer).not_to receive(:license_renewal_offer_email)

      described_class.new.perform

      expect(partner.reload.plan_type).to eq("partner_pro")
      expect(clinician.reload.plan_type).to eq("clinician")
      expect(free.reload.plan_type).to eq("free")
    end

    it "skips admins even on an enforced plan type" do
      admin = FactoryBot.create(:admin_user, plan_type: "pro_5yr")
      admin.update_columns(plan_expires_at: 1.day.ago)

      expect(UserMailer).not_to receive(:license_ended_email)
      described_class.new.perform
      expect(admin.reload.plan_type).to eq("pro_5yr")
    end
  end
end
