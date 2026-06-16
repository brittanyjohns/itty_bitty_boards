require "rails_helper"

RSpec.describe MissionControl::RevenuecatRevenueSource do
  describe ".call" do
    it "counts paid users without a stripe_subscription_id" do
      create(:user, plan_type: "basic", plan_status: "active", stripe_subscription_id: nil)
      create(:user, plan_type: "pro", plan_status: "trialing", stripe_subscription_id: nil)
      create(:user, plan_type: "basic", plan_status: "active", stripe_subscription_id: "sub_stripe")

      result = described_class.call

      expect(result[:active_subscriptions]).to eq(2)
    end

    it "excludes canceled and free users" do
      create(:user, plan_type: "basic", plan_status: "canceled", stripe_subscription_id: nil)
      create(:user, plan_type: "free", plan_status: "active", stripe_subscription_id: nil)
      create(:user, plan_type: "pro", plan_status: "active", stripe_subscription_id: nil)

      result = described_class.call

      expect(result[:active_subscriptions]).to eq(1)
    end

    it "excludes admin users" do
      create(:admin_user, plan_type: "pro", plan_status: "active", stripe_subscription_id: nil)
      create(:user, plan_type: "basic", plan_status: "active", stripe_subscription_id: nil)

      result = described_class.call

      expect(result[:active_subscriptions]).to eq(1)
    end

    it "estimates MRR from plan type and billing interval" do
      create(:user, plan_type: "basic", plan_status: "active",
             stripe_subscription_id: nil, settings: { "billing_interval" => "monthly" })
      create(:user, plan_type: "pro", plan_status: "active",
             stripe_subscription_id: nil, settings: { "billing_interval" => "yearly" })

      result = described_class.call

      basic_monthly = 499
      pro_yearly_monthly = (9999 / 12.0).round
      expect(result[:estimated_mrr_cents]).to eq(basic_monthly + pro_yearly_monthly)
    end

    it "defaults to monthly price when billing_interval is absent" do
      create(:user, plan_type: "basic", plan_status: "active",
             stripe_subscription_id: nil, settings: {})

      result = described_class.call

      expect(result[:estimated_mrr_cents]).to eq(499)
    end

    it "returns plan breakdown" do
      create(:user, plan_type: "basic", plan_status: "active", stripe_subscription_id: nil)
      create(:user, plan_type: "basic", plan_status: "active", stripe_subscription_id: nil)
      create(:user, plan_type: "pro", plan_status: "active", stripe_subscription_id: nil)

      result = described_class.call

      expect(result[:plan_breakdown]).to eq("basic" => 2, "pro" => 1)
    end

    it "returns zero counts when no RC subscribers exist" do
      result = described_class.call

      expect(result[:active_subscriptions]).to eq(0)
      expect(result[:estimated_mrr_cents]).to eq(0)
      expect(result[:plan_breakdown]).to eq({})
    end
  end
end
