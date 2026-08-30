require "rails_helper"

# Unit-level coverage for plan_type/plan_status transitions on User.
# Companion to:
#   - spec/models/user_spec.rb (basic plan defaults, initial grant)
#   - spec/requests/api/webhooks_plan_type_spec.rb (webhook-driven mutations)
#   - spec/sidekiq/downgrade_soft_trial_job_spec.rb (job-driven downgrade)
RSpec.describe User, type: :model do
  # The no-CC basic_trial soft trial was removed
  # (drafts/drop-basic-trial-option-a.md). Every new signup lands on Free.
  describe "signup plan defaults (#setup_new_user_free_plan)" do
    it "puts a blank plan_type on free with Free limits on create" do
      user = User.new(email: "a@example.com", password: "password123", plan_type: nil)
      user.save!
      expect(user.plan_type).to eq("free")
      expect(user.board_limit).to eq(User::FREE_PLAN_LIMITS["board_limit"])
    end

    it "keeps a fresh free user on free even within the old trial window" do
      user = User.new(email: "b@example.com", password: "password123", plan_type: "free")
      user.save!
      expect(user.plan_type).to eq("free")
    end

    it "does NOT overwrite an explicit 'basic' plan on create" do
      user = User.new(email: "c@example.com", password: "password123", plan_type: "basic")
      user.save!
      expect(user.plan_type).to eq("basic")
    end

    it "does NOT overwrite an explicit 'pro' plan on create" do
      user = User.new(email: "d@example.com", password: "password123", plan_type: "pro")
      user.save!
      expect(user.plan_type).to eq("pro")
    end

    it "does NOT re-promote a free user on subsequent saves" do
      user = FactoryBot.create(:user) # free
      user.touch
      expect(user.reload.plan_type).to eq("free")
    end
  end

  describe "#paid_plan?" do
    # plan_type, plan_status → expected paid_plan?
    cases = [
      # paid types, healthy status
      ["basic", "active", true],
      ["pro", "active", true],
      ["basic_trial", "active", true], # basic_trial.include?("basic") → basic? true
      ["pro", "trialing", true],
      ["basic", nil, true],
      # paid types, unpaid status
      ["pro", "canceled", false],
      ["basic", "paused", false],
      ["pro", "incomplete_expired", false],
      ["basic", "unpaid", false],
      # free types
      ["free", "active", false],
      ["free", "canceled", false],
      [nil, "active", false],
    ]

    cases.each do |plan_type, plan_status, expected|
      it "is #{expected} for plan_type=#{plan_type.inspect} plan_status=#{plan_status.inspect}" do
        user = FactoryBot.build_stubbed(:user, plan_type: plan_type, plan_status: plan_status, role: "user")
        expect(user.paid_plan?).to eq(expected)
      end
    end

    it "is true for admins regardless of plan_type/status" do
      admin = FactoryBot.build_stubbed(:admin_user, plan_type: "free", plan_status: "canceled")
      expect(admin.paid_plan?).to eq(true)
    end
  end

  describe "#pin_default_editable_board!" do
    it "no-ops when editable_board_id is already set" do
      user = FactoryBot.create(:user)
      board = FactoryBot.create(:board, user: user)
      user.update!(editable_board_id: board.id)

      expect { user.pin_default_editable_board! }.not_to change { user.reload.editable_board_id }
    end

    it "no-ops when the user owns zero boards" do
      user = FactoryBot.create(:user)
      expect { user.pin_default_editable_board! }.not_to change { user.reload.editable_board_id }
      expect(user.reload.editable_board_id).to be_nil
    end

    it "pins the most-recently-updated board when no favorite exists" do
      user = FactoryBot.create(:user)
      FactoryBot.create(:board, user: user)
      newest = FactoryBot.create(:board, user: user)

      user.pin_default_editable_board!
      expect(user.reload.editable_board_id).to eq(newest.id)
    end
  end

  # This method had a bare begin/end with no rescue, unlike its siblings
  # send_welcome_email and send_welcome_receipt_email. A Mailchimp blip would
  # propagate out of it, which violates the "external-service failures fail
  # soft" invariant — the CRM sync is not allowed to break a signup.
  describe "#send_general_welcome_email" do
    let(:user) { FactoryBot.create(:user) }

    it "does not raise when the Mailchimp sync fails" do
      allow(user).to receive(:update_mailchimp_subscription).and_raise(StandardError, "mailchimp down")
      expect(Rails.logger).to receive(:error).with(/Error sending general welcome email/)
      expect { user.send_general_welcome_email }.not_to raise_error
    end

    it "still flags the welcome as sent when the Mailchimp sync fails" do
      allow(user).to receive(:update_mailchimp_subscription).and_raise(StandardError, "mailchimp down")
      user.send_general_welcome_email
      expect(user.reload.settings["welcome_email_sent"]).to be(true)
    end

    it "does not raise when the mailer itself fails" do
      allow(UserMailer).to receive(:welcome_email).and_raise(StandardError, "smtp down")
      expect { user.send_general_welcome_email }.not_to raise_error
    end
  end
end
