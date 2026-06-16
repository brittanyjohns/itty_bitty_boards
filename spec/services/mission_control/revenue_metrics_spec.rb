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

  let(:rc_data) do
    {
      source: "revenuecat_local",
      active_subscriptions: 5,
      estimated_mrr_cents: 2995,
      estimated_mrr_usd: 29.95,
      plan_breakdown: { "basic" => 3, "pro" => 2 },
    }
  end

  before do
    allow(MissionControl::StripeRevenueSource).to receive(:call).and_return(stripe_data)
    allow(MissionControl::RevenuecatRevenueSource).to receive(:call).and_return(rc_data)
  end

  describe ".call" do
    it "combines Stripe and RevenueCat subscription counts" do
      result = described_class.call

      expect(result[:active_subscriptions]).to eq(90)
      expect(result.dig(:stripe, :active_subscriptions)).to eq(85)
      expect(result.dig(:revenuecat, :active_subscriptions)).to eq(5)
    end

    it "combines MRR from both sources" do
      result = described_class.call

      expect(result[:estimated_mrr_cents]).to eq(5967 + 2995)
      expect(result[:mrr_usd]).to eq(((5967 + 2995) / 100.0).round(2))
    end

    it "ignores the local Subscription table" do
      user = create(:user)
      Subscription.create!(user: user, status: "active", price_in_cents: 999,
                           stripe_subscription_id: "sub_local")

      result = described_class.call

      expect(result[:active_subscriptions]).to eq(90)
    end

    it "nests per-source breakdowns under :stripe and :revenuecat" do
      result = described_class.call

      expect(result.dig(:stripe, :plan_breakdown)).to eq("basic_plan" => 4, "pro_plan" => 1)
      expect(result.dig(:revenuecat, :plan_breakdown)).to eq("basic" => 3, "pro" => 2)
    end

    it "sets revenue_source to stripe+revenuecat" do
      result = described_class.call
      expect(result[:revenue_source]).to eq("stripe+revenuecat")
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

    it "handles Stripe error gracefully with RC still counted" do
      allow(MissionControl::StripeRevenueSource).to receive(:call).and_return(
        stripe_data.merge(active_subscriptions: nil, mrr_cents: nil, error: "Stripe down")
      )

      result = described_class.call

      expect(result[:active_subscriptions]).to eq(5)
      expect(result[:estimated_mrr_cents]).to eq(2995)
      expect(result[:revenue_error]).to eq("Stripe down")
    end
  end
end
