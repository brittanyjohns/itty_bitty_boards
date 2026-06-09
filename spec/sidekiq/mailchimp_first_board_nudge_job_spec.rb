require "rails_helper"

RSpec.describe MailchimpFirstBoardNudgeJob, type: :job do
  subject(:job) { described_class.new }

  before { MailchimpEventJob.clear }

  def create_eligible_user(overrides = {})
    user = create(:user, **overrides.except(:created_at))
    timestamp = overrides[:created_at] || 60.hours.ago
    user.update_column(:created_at, timestamp)
    user
  end

  describe "#perform" do
    context "when a Free user signed up 48-72h ago with no boards" do
      it "enqueues MailchimpEventJob with journey_key=first_board_nudge" do
        user = create_eligible_user
        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)

        args = MailchimpEventJob.jobs.last["args"]
        expect(args).to eq([user.id, "journey", { "journey_key" => "first_board_nudge" }])
      end

      it "flags the user in settings so they aren't nudged again" do
        user = create_eligible_user
        job.perform
        expect(user.reload.settings["first_board_nudge_sent"]).to eq(true)
      end
    end

    context "when the user already has a board" do
      it "does not enqueue" do
        user = create_eligible_user
        create(:board, user: user)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
        expect(user.reload.settings["first_board_nudge_sent"]).not_to eq(true)
      end
    end

    context "when the user has already been nudged" do
      it "does not re-enqueue" do
        user = create_eligible_user
        user.update!(settings: (user.settings || {}).merge("first_board_nudge_sent" => true))
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user is an admin" do
      it "is skipped even if otherwise eligible" do
        admin = create(:admin_user)
        admin.update_column(:created_at, 60.hours.ago)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user is a demo/internal account" do
      it "is skipped (not enqueued, not flagged) even if otherwise eligible" do
        user = create_eligible_user(email: "qa@speakanyway.com")
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
        expect(user.reload.settings["first_board_nudge_sent"]).not_to eq(true)
      end
    end

    context "when the user signed up less than 48h ago" do
      it "is skipped" do
        create_eligible_user(created_at: 24.hours.ago)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user signed up more than 72h ago" do
      it "is skipped (already missed the window)" do
        create_eligible_user(created_at: 5.days.ago)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when one user's save raises" do
      it "logs and continues processing the rest" do
        user_a = create_eligible_user
        user_b = create_eligible_user

        # Make save! blow up only for user_a
        allow_any_instance_of(User).to receive(:save!).and_wrap_original do |original, *args|
          if original.receiver.id == user_a.id
            raise "boom"
          else
            original.call(*args)
          end
        end
        expect(Rails.logger).to receive(:error).with(/failed for user #{user_a.id}/)
        allow(Rails.logger).to receive(:info)

        # user_a's enqueue happens before the failing save!, so it's still in
        # the queue (Mailchimp's own journey dedupe catches a stray double).
        # user_b succeeds end-to-end and ends up flagged.
        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(2)
        expect(user_b.reload.settings["first_board_nudge_sent"]).to eq(true)
        expect(user_a.reload.settings["first_board_nudge_sent"]).not_to eq(true)
      end
    end
  end
end
