require "rails_helper"

RSpec.describe RevenueCatTrialEndingJob, type: :job do
  subject(:job) { described_class.new }

  before { MailchimpTrialWrapJob.clear }

  # Eligible by default: a RevenueCat trialist whose trial ends in 2 days
  # (inside the 3-day lead window).
  def create_rc_trialist(trial_ends_at: 2.days.from_now, extra_settings: {})
    create(:user,
      plan_type: "pro",
      plan_status: "trialing",
      settings: { "trial_ends_at" => trial_ends_at&.iso8601 }.merge(extra_settings))
  end

  describe "#perform" do
    it "enqueues MailchimpTrialWrapJob with the trial-end epoch and flags the user" do
      ends_at = 2.days.from_now
      user = create_rc_trialist(trial_ends_at: ends_at)

      expect { job.perform }.to change(MailchimpTrialWrapJob.jobs, :size).by(1)
      args = MailchimpTrialWrapJob.jobs.last["args"]
      expect(args.first).to eq(user.id)
      expect(args.last).to be_within(60).of(ends_at.to_i)
      expect(user.reload.settings["rc_trial_wrap_sent"]).to eq(true)
    end

    it "does not re-nudge a user already flagged" do
      create_rc_trialist(extra_settings: { "rc_trial_wrap_sent" => true })
      expect { job.perform }.not_to change(MailchimpTrialWrapJob.jobs, :size)
    end

    it "skips a trial ending beyond the lead window" do
      create_rc_trialist(trial_ends_at: 10.days.from_now)
      expect { job.perform }.not_to change(MailchimpTrialWrapJob.jobs, :size)
    end

    it "skips a trial whose end is already in the past (stale)" do
      create_rc_trialist(trial_ends_at: 1.day.ago)
      expect { job.perform }.not_to change(MailchimpTrialWrapJob.jobs, :size)
    end

    it "skips non-trialing users even if they somehow carry trial_ends_at" do
      user = create_rc_trialist
      user.update!(plan_status: "active")
      expect { job.perform }.not_to change(MailchimpTrialWrapJob.jobs, :size)
    end

    it "skips Stripe trialists (no trial_ends_at set)" do
      create(:user, plan_type: "pro", plan_status: "trialing", settings: {})
      expect { job.perform }.not_to change(MailchimpTrialWrapJob.jobs, :size)
    end

    it "skips admins" do
      create_rc_trialist.update!(role: "admin")
      expect { job.perform }.not_to change(MailchimpTrialWrapJob.jobs, :size)
    end

    it "respects REVENUECAT_TRIAL_REMINDER_LEAD_DAYS" do
      create_rc_trialist(trial_ends_at: 6.days.from_now)

      # Default 3-day window: not yet eligible.
      expect { job.perform }.not_to change(MailchimpTrialWrapJob.jobs, :size)

      # Widen the lead to 7 days: now in range.
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("REVENUECAT_TRIAL_REMINDER_LEAD_DAYS").and_return("7")
      expect { job.perform }.to change(MailchimpTrialWrapJob.jobs, :size).by(1)
    end
  end
end
