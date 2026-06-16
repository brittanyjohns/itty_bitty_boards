require "rails_helper"

RSpec.describe MissionControl::RevenueMetrics do
  let(:stripe_data) do
    {
      source: "stripe",
      cached_at: Time.current.iso8601,
      active_subscriptions: 85,
      mrr_cents: 5967,
      mrr_usd: 59.67,
      new_subs_7d: 3,
      plan_breakdown: { "basic_plan" => 4, "pro_plan" => 1 },
    }
  end

  before do
    allow(MissionControl::StripeRevenueSource).to receive(:call).and_return(stripe_data)
  end

  describe ".call" do
    it "pulls subscription counts from Stripe, not the local table" do
      user = create(:user)
      Subscription.create!(user: user, status: "active", price_in_cents: 999,
                           stripe_subscription_id: "sub_local")

      result = described_class.call

      expect(result[:active_subscriptions]).to eq(85)
      expect(result[:estimated_mrr_cents]).to eq(5967)
      expect(result[:mrr_usd]).to eq(59.67)
    end

    it "includes Stripe plan breakdown separately from user plan breakdown" do
      result = described_class.call
      expect(result[:stripe_plan_breakdown]).to eq("basic_plan" => 4, "pro_plan" => 1)
      expect(result[:revenue_source]).to eq("stripe")
    end

    it "counts paid and free users from the local database" do
      create(:user, plan_type: "basic")
      create(:user, plan_type: "pro")
      create(:user, plan_type: "free")
      create(:admin_user, plan_type: "basic")

      result = described_class.call

      expect(result[:paid_users]).to eq(2)
      expect(result[:free_users]).to eq(1)
    end

    it "provides a user plan_breakdown from the local database" do
      create(:user, plan_type: "basic")
      create(:user, plan_type: "free")

      result = described_class.call

      expect(result[:plan_breakdown]).to include("basic" => 1, "free" => 1)
    end

    it "surfaces Stripe errors without raising" do
      allow(MissionControl::StripeRevenueSource).to receive(:call).and_return(
        stripe_data.merge(active_subscriptions: nil, mrr_cents: nil, error: "Stripe down")
      )

      result = described_class.call
      expect(result[:active_subscriptions]).to be_nil
      expect(result[:revenue_error]).to eq("Stripe down")
    end
  end
end
