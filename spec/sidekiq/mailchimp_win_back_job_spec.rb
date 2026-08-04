require "rails_helper"

RSpec.describe MailchimpWinBackJob, type: :job do
  subject(:job) { described_class.new }

  before do
    MailchimpEventJob.clear
    allow(MailchimpClient).to receive(:journey_deliverable?).with("win_back").and_return(true)
  end

  # Eligible by default: last sign-in 21 days ago (inside the 14-30d window),
  # with one board. Caller adds boards as needed.
  def create_dormant_user(overrides = {})
    last_sign_in_at = overrides.key?(:last_sign_in_at) ? overrides.delete(:last_sign_in_at) : 21.days.ago
    user = create(:user, **overrides)
    user.update_column(:last_sign_in_at, last_sign_in_at)
    user
  end

  describe "#perform" do
    context "when a non-admin user with a board went dormant 14-30 days ago" do
      it "enqueues MailchimpEventJob with journey_key=win_back" do
        user = create_dormant_user
        create(:board, user: user)

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
        expect(MailchimpEventJob.jobs.last["args"]).to eq([user.id, "journey", { "journey_key" => "win_back" }])
      end

      it "flags the user so they aren't nudged again" do
        user = create_dormant_user
        create(:board, user: user)

        job.perform
        expect(user.reload.settings["win_back_nudge_sent"]).to eq(true)
      end
    end

    context "when the user has no role (the shape every password signup has)" do
      it "is still nudged — role is nullable and `where.not` would drop them" do
        user = create_dormant_user(role: nil)
        create(:board, user: user)

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
        expect(MailchimpEventJob.jobs.last["args"].first).to eq(user.id)
      end
    end

    context "the per-run send cap" do
      before { allow(ENV).to receive(:[]).and_call_original }

      it "stops at WIN_BACK_MAX_PER_RUN and leaves the rest unflagged" do
        3.times { create(:board, user: create_dormant_user) }
        allow(ENV).to receive(:[]).with("WIN_BACK_MAX_PER_RUN").and_return("2")

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(2)
        expect(User.where("settings @> ?", { "win_back_nudge_sent" => true }.to_json).count).to eq(2)
      end

      it "picks the remainder up on the next run" do
        3.times { create(:board, user: create_dormant_user) }
        allow(ENV).to receive(:[]).with("WIN_BACK_MAX_PER_RUN").and_return("2")

        job.perform
        expect { described_class.new.perform }.to change(MailchimpEventJob.jobs, :size).by(1)
      end

      it "defaults to 100 rather than unlimited" do
        expect(job.send(:max_per_run)).to eq(100)
      end
    end

    context "when the user has no boards" do
      it "is skipped (distinct from the legacy never-made-a-board journey)" do
        create_dormant_user
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user was already win-back-nudged" do
      it "does not re-enqueue" do
        user = create_dormant_user(settings: { "win_back_nudge_sent" => true })
        create(:board, user: user)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user signed in within the last 14 days" do
      it "is skipped (not dormant yet)" do
        user = create_dormant_user(last_sign_in_at: 5.days.ago)
        create(:board, user: user)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user has been dormant longer than 30 days" do
      it "is skipped (out of the recently-dormant window)" do
        user = create_dormant_user(last_sign_in_at: 45.days.ago)
        create(:board, user: user)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when the user is an admin" do
      it "is skipped even if otherwise eligible" do
        admin = create(:admin_user)
        admin.update_column(:last_sign_in_at, 21.days.ago)
        create(:board, user: admin)
        expect { job.perform }.not_to change(MailchimpEventJob.jobs, :size)
      end
    end

    context "when one user's save raises" do
      it "logs and continues processing the rest" do
        user_a = create_dormant_user
        create(:board, user: user_a)
        user_b = create_dormant_user
        create(:board, user: user_b)

        allow_any_instance_of(User).to receive(:save!).and_wrap_original do |original, *args|
          raise "boom" if original.receiver.id == user_a.id

          original.call(*args)
        end
        expect(Rails.logger).to receive(:error).with(/failed for user #{user_a.id}/)
        allow(Rails.logger).to receive(:info)

        expect { job.perform }.to change(MailchimpEventJob.jobs, :size).by(2)
        expect(user_b.reload.settings["win_back_nudge_sent"]).to eq(true)
        expect(user_a.reload.settings["win_back_nudge_sent"]).not_to eq(true)
      end
    end
  end
end
