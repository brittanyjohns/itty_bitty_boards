require "rails_helper"

RSpec.describe DowngradePastDueJob, type: :job do
  subject(:job) { described_class.new }

  # A past_due Basic user whose grace window has already elapsed.
  def create_lapsed_user(overrides = {})
    since = overrides.delete(:past_due_since) { 45.days.ago }
    attrs = {
      plan_type: "basic",
      plan_status: "past_due",
      stripe_customer_id: "cus_test123",
      stripe_subscription_id: "sub_test123",
    }.merge(overrides)
    user = FactoryBot.create(:user, **attrs)
    if since
      user.settings = (user.settings || {}).merge(User::PAST_DUE_SINCE_KEY => since.utc.iso8601)
      user.save!
    else
      # Simulate a row that went past_due before the stamp existed: strip what
      # the model callback just wrote, without firing callbacks again.
      user.update_column(:settings, (user.settings || {}).except(User::PAST_DUE_SINCE_KEY))
    end
    user
  end

  def stub_stripe_status(status)
    allow(Stripe::Subscription).to receive(:retrieve).and_return(double(status: status))
  end

  before { stub_stripe_status("past_due") }

  describe "#perform" do
    context "when the grace window has elapsed and Stripe confirms no recovery" do
      it "drops the user to free" do
        user = create_lapsed_user

        expect { job.perform }.to change { user.reload.plan_type }.from("basic").to("free")
        expect(user.plan_status).to eq("canceled")
        expect(user.paid_plan_type).to eq("basic")
        expect(user.paid_plan?).to be false
      end

      it "retains the user's boards, locking the over-limit ones instead of deleting" do
        user = create_lapsed_user
        create(:board, user: user)
        newest = create(:board, user: user)

        expect { job.perform }.not_to change { user.boards.count }
        expect(user.reload.editable_board_id).to eq(newest.id)
      end

      it "clears the past_due stamp on the way out" do
        user = create_lapsed_user

        job.perform

        expect(user.reload.settings[User::PAST_DUE_SINCE_KEY]).to be_nil
      end

      it "emails the user that the subscription ended" do
        user = create_lapsed_user

        expect(UserMailer).to receive(:subscription_canceled_email).with(user_matching(user)).and_call_original

        job.perform
      end
    end

    context "when the account is still inside the grace window" do
      it "leaves the plan alone" do
        user = create_lapsed_user(past_due_since: 5.days.ago)

        expect { job.perform }.not_to change { user.reload.plan_type }
        expect(user.plan_status).to eq("past_due")
      end
    end

    context "when the account went past_due before the stamp existed" do
      it "stamps it and defers the downgrade to a later run" do
        user = create_lapsed_user(past_due_since: nil)

        expect { job.perform }.not_to change { user.reload.plan_type }
        expect(user.past_due_since).to be_within(1.minute).of(Time.current)
      end

      it "downgrades once that fresh window elapses" do
        user = create_lapsed_user(past_due_since: nil)
        job.perform

        user.stamp_past_due!(45.days.ago)

        expect { job.perform }.to change { user.reload.plan_type }.from("basic").to("free")
      end
    end

    context "when Stripe says the subscription recovered" do
      it "heals the user back to active instead of downgrading" do
        user = create_lapsed_user
        stub_stripe_status("active")

        expect { job.perform }.not_to change { user.reload.plan_type }
        expect(user.plan_status).to eq("active")
        expect(user.settings[User::PAST_DUE_SINCE_KEY]).to be_nil
      end
    end

    context "when Stripe cannot be reached" do
      it "skips the user rather than downgrading blind" do
        user = create_lapsed_user
        allow(Stripe::Subscription).to receive(:retrieve).and_raise(Stripe::APIConnectionError.new("down"))

        expect { job.perform }.not_to change { user.reload.plan_type }
        expect(user.plan_status).to eq("past_due")
      end
    end

    context "when Stripe no longer knows the subscription" do
      it "treats it as lapsed and downgrades" do
        user = create_lapsed_user
        allow(Stripe::Subscription).to receive(:retrieve).and_raise(Stripe::InvalidRequestError.new("no such sub", "id"))

        expect { job.perform }.to change { user.reload.plan_type }.from("basic").to("free")
      end
    end

    context "when the account has no Stripe subscription (RevenueCat billing issue)" do
      it "downgrades without a Stripe call" do
        user = create_lapsed_user(stripe_subscription_id: nil)
        expect(Stripe::Subscription).not_to receive(:retrieve)

        expect { job.perform }.to change { user.reload.plan_type }.from("basic").to("free")
      end
    end

    context "with accounts the job does not own" do
      it "leaves admins alone" do
        admin = create_lapsed_user(role: "admin")

        expect { job.perform }.not_to change { admin.reload.plan_type }
      end

      it "leaves basic_trial users to DowngradeSoftTrialJob" do
        user = create_lapsed_user(plan_type: "basic_trial")

        expect { job.perform }.not_to change { user.reload.plan_type }
      end

      it "leaves users who are not past_due alone" do
        user = create_lapsed_user(plan_status: "active", past_due_since: nil)

        expect { job.perform }.not_to change { user.reload.plan_type }
      end
    end

    it "honors PAST_DUE_GRACE_DAYS" do
      user = create_lapsed_user(past_due_since: 10.days.ago)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("PAST_DUE_GRACE_DAYS").and_return("7")

      expect { job.perform }.to change { user.reload.plan_type }.from("basic").to("free")
    end
  end

  # apply_free_plan reloads/saves the user, so identity is by id, not object.
  def user_matching(user)
    satisfy { |arg| arg.id == user.id }
  end
end
