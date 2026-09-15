require "rails_helper"

# A paid plan_type says what an account can DO, not who BILLS for it. The
# pricing page read "paid" as "self-serve Stripe subscriber" and opened the
# in-app plan switch for an admin-comped account, which can only 422
# no_subscription — there is nothing at Stripe to change. Sending that account
# to Checkout instead is only safe once the server can also say "the App Store
# bills this one", or an IAP subscriber is sold a second, web subscription.
RSpec.describe User, "#billing_source" do
  def user_with(**attrs)
    FactoryBot.build(:user, **{ plan_type: "pro", plan_status: "active", settings: {} }.merge(attrs))
  end

  it "is none for a free account" do
    expect(user_with(plan_type: "free").billing_source).to eq("none")
  end

  it "is none for a paid plan_type whose status is no longer paid" do
    expect(user_with(plan_status: "canceled").billing_source).to eq("none")
  end

  it "is stripe when a Stripe subscription backs the plan" do
    expect(user_with(stripe_subscription_id: "sub_123").billing_source).to eq("stripe")
  end

  it "is stripe for a Stripe trialist" do
    expect(user_with(plan_status: "trialing", stripe_subscription_id: "sub_123").billing_source).to eq("stripe")
  end

  it "is app_store when RevenueCat bills the plan" do
    user = user_with(settings: { "billing_provider" => "revenuecat" })
    expect(user.billing_source).to eq("app_store")
  end

  it "prefers a live Stripe subscription over a leftover RevenueCat stamp" do
    user = user_with(stripe_subscription_id: "sub_123", settings: { "billing_provider" => "revenuecat" })
    expect(user.billing_source).to eq("stripe")
  end

  it "is manual for a paid plan with no provider behind it (an admin comp)" do
    expect(user_with(plan_type: "basic").billing_source).to eq("manual")
  end

  # purchase_platform is written once and never cleared, so a lapsed IAP user
  # an admin later comps would still look App-Store-billed and be kept away from
  # Checkout for good. The stamp is the signal; purchase_platform is not.
  it "does not treat a bare purchase_platform as App Store billing" do
    user = user_with(settings: { "purchase_platform" => "ios" })
    expect(user.billing_source).to eq("manual")
  end

  it "is published on api_view" do
    user = FactoryBot.create(:user, plan_type: "basic", plan_status: "active")
    expect(user.api_view[:billing_source]).to eq("manual")
  end
end

RSpec.describe Billing::PlanTransitions, ".apply_free_plan" do
  # A plan that ended has no provider. A leftover stamp would mark a later
  # admin comp as App-Store-billed and hide Checkout from it.
  it "clears the RevenueCat billing_provider stamp" do
    user = FactoryBot.create(:user, plan_type: "pro", plan_status: "active",
                                    settings: { "billing_provider" => "revenuecat" })

    described_class.apply_free_plan(user, "canceled")

    expect(user.reload.settings).not_to have_key("billing_provider")
    expect(user.billing_source).to eq("none")
  end
end
