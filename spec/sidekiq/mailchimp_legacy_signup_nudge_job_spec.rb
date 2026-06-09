require "rails_helper"

RSpec.describe MailchimpLegacySignupNudgeJob, type: :job do
  subject(:job) { described_class.new }

  before { MailchimpEventJob.clear }

  # Eligible by default: created 90d ago, last sign-in 60d ago, no boards.
  def create_legacy_user(overrides = {})
    created_at = overrides.delete(:created_at) || 90.days.ago
    last_sign_in_at = overrides.key?(:last_sign_in_at) ? overrides.delete(:last_sign_in_at) : 60.days.ago
    user = create(:user, **overrides)
    user.update_columns(created_at: created_at, last_sign_in_at: last_sign_in_at)
    user
  end

  describe "#perform" do
    context "when a non-admin user is old, board-less, and long-inactive" do
      it "enqueues MailchimpEventJob with journey_key=legacy_signup_nudge" do
        user = create_legacy_user
        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)

        args = MailchimpEventJob.jobs.last["args"]
        expect(args).to eq([user.id, "journey", { "journey_key" => "legacy_signup_nudge" }])
      end

      it "flags the user so they aren't nudged again" do
        user = create_legacy_user
        job.perform
        expect(user.reload.settings["legacy_signup_nudge_sent"]).to eq(true)
      end

      it "still fires for a user who already got the 48h first_board_nudge (second touch)" do
        user = create_legacy_user(settings: { "first_board_nudge_sent" => true })
        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
        expect(user.reload.settings["legacy_signup_nudge_sent"]).to eq(true)
      end
    end

    context "when the user already has a board" do
      it "does not enqueue" do
        user = create_legacy_user
        create(:board, user: user)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
        expect(user.reload.settings["legacy_signup_nudge_sent"]).not_to eq(true)
      end
    end

    context "when the user was already legacy-nudged" do
      it "does not re-enqueue" do
        create_legacy_user(settings: { "legacy_signup_nudge_sent" => true })
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user signed in recently" do
      it "is skipped (not a cold account)" do
        create_legacy_user(last_sign_in_at: 3.days.ago)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user has never signed in (nil last_sign_in_at)" do
      it "still qualifies if old and board-less" do
        create_legacy_user(last_sign_in_at: nil)
        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
      end
    end

    context "when the account is too new" do
      it "is skipped (inside the recent-signup window)" do
        create_legacy_user(created_at: 5.days.ago, last_sign_in_at: nil)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user is an admin" do
      it "is skipped even if otherwise eligible" do
        admin = create(:admin_user)
        admin.update_columns(created_at: 90.days.ago, last_sign_in_at: 60.days.ago)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user is a demo/internal account" do
      it "is skipped (not enqueued, not flagged) even if otherwise eligible" do
        user = create_legacy_user(email: "qa@speakanyway.com")
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
        expect(user.reload.settings["legacy_signup_nudge_sent"]).not_to eq(true)
      end
    end

    context "ENV threshold overrides" do
      it "honors LEGACY_SIGNUP_NUDGE_AGE_DAYS" do
        create_legacy_user(created_at: 20.days.ago, last_sign_in_at: nil)

        # Default 30d age would skip a 20-day-old account; lower the bar to 14.
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("LEGACY_SIGNUP_NUDGE_AGE_DAYS").and_return("14")

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
      end
    end

    context "when one user's save raises" do
      it "logs and continues processing the rest" do
        user_a = create_legacy_user
        user_b = create_legacy_user

        allow_any_instance_of(User).to receive(:save!).and_wrap_original do |original, *args|
          raise "boom" if original.receiver.id == user_a.id

          original.call(*args)
        end
        expect(Rails.logger).to receive(:error).with(/failed for user #{user_a.id}/)
        allow(Rails.logger).to receive(:info)

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(2)
        expect(user_b.reload.settings["legacy_signup_nudge_sent"]).to eq(true)
        expect(user_a.reload.settings["legacy_signup_nudge_sent"]).not_to eq(true)
      end
    end
  end
end
