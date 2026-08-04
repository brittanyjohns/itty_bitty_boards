require "rails_helper"

RSpec.describe MailchimpFirstBoardNudgeJob, type: :job do
  subject(:job) { described_class.new }

  before do
    MailchimpEventJob.clear
    allow(MailchimpClient).to receive(:journey_deliverable?).with("first_board_nudge").and_return(true)
  end

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

    context "when the user has no role (the shape every password signup has)" do
      it "is still nudged — role is nullable and `where.not` would drop them" do
        user = create_eligible_user(role: nil)
        expect(user.reload.role).to be_nil

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
        expect(MailchimpEventJob.jobs.last["args"].first).to eq(user.id)
      end
    end

    context "when the journey is unconfigured or journeys are disabled" do
      it "nudges nobody and leaves the flag unset so the backlog survives" do
        allow(MailchimpClient).to receive(:journey_deliverable?).with("first_board_nudge").and_return(false)
        user = create_eligible_user

        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
        expect(user.reload.settings["first_board_nudge_sent"]).not_to eq(true)
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

    context "when the user signed up less than 48h ago" do
      it "is skipped" do
        create_eligible_user(created_at: 24.hours.ago)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    # The window is a catch-up sweep, not a single-day band — a user whose own
    # eligibility day was missed (outage, two skipped runs) must still be
    # reachable, since nothing else sweeps for them.
    context "when a user's nudge day was missed" do
      it "still nudges someone who signed up 5 days ago" do
        user = create_eligible_user(created_at: 5.days.ago)
        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
        expect(MailchimpEventJob.jobs.last["args"].first).to eq(user.id)
      end

      it "still nudges someone at the far edge of the window (13 days)" do
        create_eligible_user(created_at: 13.days.ago)
        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
      end
    end

    context "when the user signed up longer ago than the window" do
      it "is skipped — stale, and legacy_signup_nudge owns that cohort" do
        create_eligible_user(created_at: 20.days.ago)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "ENV threshold overrides" do
      before { allow(ENV).to receive(:[]).and_call_original }

      it "honors FIRST_BOARD_NUDGE_MAX_AGE_DAYS" do
        create_eligible_user(created_at: 10.days.ago)
        allow(ENV).to receive(:[]).with("FIRST_BOARD_NUDGE_MAX_AGE_DAYS").and_return("7")

        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end

      it "honors FIRST_BOARD_NUDGE_MIN_AGE_HOURS" do
        create_eligible_user(created_at: 24.hours.ago)
        allow(ENV).to receive(:[]).with("FIRST_BOARD_NUDGE_MIN_AGE_HOURS").and_return("12")

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
      end
    end

    context "the per-run send cap" do
      before { allow(ENV).to receive(:[]).and_call_original }

      it "stops at FIRST_BOARD_NUDGE_MAX_PER_RUN and leaves the rest unflagged" do
        3.times { |i| create_eligible_user(created_at: (3 + i).days.ago) }
        allow(ENV).to receive(:[]).with("FIRST_BOARD_NUDGE_MAX_PER_RUN").and_return("2")

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(2)
        expect(User.where("settings @> ?", { "first_board_nudge_sent" => true }.to_json).count).to eq(2)
      end

      it "picks the remainder up on the next run" do
        3.times { |i| create_eligible_user(created_at: (3 + i).days.ago) }
        allow(ENV).to receive(:[]).with("FIRST_BOARD_NUDGE_MAX_PER_RUN").and_return("2")

        job.perform
        expect { described_class.new.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
      end

      it "defaults to 100 rather than unlimited" do
        expect(job.send(:max_per_run)).to eq(100)
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
