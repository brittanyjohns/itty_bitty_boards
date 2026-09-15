require "rails_helper"
require "rake"

# Backfill for User#billing_source. App Store subscribers from before the
# webhook stamped `billing_provider` look exactly like admin comps (paid, no
# Stripe subscription), so the pricing page can't tell which of them may be
# sent to web Checkout. The credit ledger remembers who granted the plan.
RSpec.describe "billing:stamp_revenuecat_provider rake task", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["billing:stamp_revenuecat_provider"] }

  def run_task
    task.reenable
    task.invoke
  end

  around do |example|
    original = ENV["APPLY"]
    example.run
    ENV["APPLY"] = original
  end

  def grant!(user, **metadata)
    CreditService.grant_plan!(
      user,
      amount: 100,
      period_end: 30.days.from_now,
      stripe_event_id: "evt_#{SecureRandom.hex(6)}",
      metadata: metadata,
    )
  end

  def paid_user(**attrs)
    FactoryBot.create(:user, **{ plan_type: "pro", plan_status: "active" }.merge(attrs))
  end

  # An App Store subscriber whose newest grant is the monthly refresh, which
  # carries no provider — the reason the task can't just read the newest grant.
  let!(:app_store_user) do
    paid_user.tap do |u|
      grant!(u, provider: "revenuecat", source: "INITIAL_PURCHASE")
      grant!(u, source: "refresh_credits_job", plan_type: "pro")
    end
  end

  let!(:comped_user) { paid_user(plan_type: "basic") }

  # Was an App Store subscriber, lapsed to Free, then an admin comped them. The
  # free-plan grant is newer than the RevenueCat one, so App Store no longer bills.
  let!(:lapsed_then_comped) do
    paid_user(plan_type: "basic").tap do |u|
      grant!(u, provider: "revenuecat", source: "INITIAL_PURCHASE")
      grant!(u, reason: "subscription_canceled", previous_plan_type: "pro")
    end
  end

  let!(:stripe_user) do
    paid_user(stripe_subscription_id: "sub_123").tap { |u| grant!(u, provider: "revenuecat") }
  end

  let!(:free_user) do
    FactoryBot.create(:user, plan_type: "free").tap { |u| grant!(u, provider: "revenuecat") }
  end

  def stamped_ids
    User.where("settings->>'billing_provider' = 'revenuecat'").pluck(:id)
  end

  it "reports what it would stamp and writes nothing by default" do
    ENV.delete("APPLY")

    expect { run_task }.to output(/would stamp user=#{app_store_user.id}\b/).to_stdout
    expect(stamped_ids).to be_empty
  end

  it "stamps only accounts the App Store still bills with APPLY=1" do
    ENV["APPLY"] = "1"

    expect { run_task }.to output(/stamped 1 account/).to_stdout
    expect(stamped_ids).to contain_exactly(app_store_user.id)
    expect(app_store_user.reload.billing_source).to eq("app_store")
    expect(comped_user.reload.billing_source).to eq("manual")
    expect(lapsed_then_comped.reload.billing_source).to eq("manual")
  end

  it "is idempotent" do
    ENV["APPLY"] = "1"
    run_task

    expect { run_task }.to output(/stamped 0 account/).to_stdout
  end
end
