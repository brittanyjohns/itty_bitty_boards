require "rails_helper"

RSpec.describe MissionControl::StripeRevenueSource do
  let(:monthly_price) do
    double("Price",
      unit_amount: 999,
      recurring: double(interval: "month"),
      metadata: { "plan_type" => "basic_plan" },
      lookup_key: nil,
      id: "price_basic_monthly")
  end

  let(:yearly_price) do
    double("Price",
      unit_amount: 9999,
      recurring: double(interval: "year"),
      metadata: { "plan_type" => "pro_plan" },
      lookup_key: nil,
      id: "price_pro_yearly")
  end

  let(:monthly_sub) do
    double("Subscription",
      id: "sub_monthly",
      created: 2.days.ago.to_i,
      items: double(data: [double(price: monthly_price)]))
  end

  let(:yearly_sub) do
    double("Subscription",
      id: "sub_yearly",
      created: 10.days.ago.to_i,
      items: double(data: [double(price: yearly_price)]))
  end

  let(:active_list) do
    double("List", data: [monthly_sub, yearly_sub], has_more: false)
  end

  let(:trialing_list) do
    double("List", data: [], has_more: false)
  end

  before do
    stub_rails_cache

    allow(Stripe::Subscription).to receive(:list)
      .with(hash_including(status: "active"))
      .and_return(active_list)

    allow(Stripe::Subscription).to receive(:list)
      .with(hash_including(status: "trialing"))
      .and_return(trialing_list)
  end

  describe ".call" do
    it "returns active subscription count from Stripe" do
      result = described_class.call
      expect(result[:active_subscriptions]).to eq(2)
    end

    it "computes MRR normalizing yearly to monthly" do
      result = described_class.call
      expected_monthly = 999 + (9999 / 12.0).round
      expect(result[:mrr_cents]).to eq(expected_monthly)
      expect(result[:mrr_usd]).to eq((expected_monthly / 100.0).round(2))
    end

    it "counts new subscriptions in the last 7 days" do
      result = described_class.call
      expect(result[:new_subs_7d]).to eq(1)
    end

    it "breaks down by plan name from price metadata" do
      result = described_class.call
      expect(result[:plan_breakdown]).to include("basic_plan" => 1, "pro_plan" => 1)
    end

    it "sets source to stripe" do
      result = described_class.call
      expect(result[:source]).to eq("stripe")
    end

    it "includes cached_at timestamp" do
      result = described_class.call
      expect(result[:cached_at]).to be_present
    end

    it "includes trialing subscriptions" do
      trialing_price = double("Price",
        unit_amount: 499,
        recurring: double(interval: "month"),
        metadata: { "plan_type" => "basic_plan" },
        lookup_key: nil,
        id: "price_trial")

      trialing_sub = double("Subscription",
        id: "sub_trial",
        created: 1.day.ago.to_i,
        items: double(data: [double(price: trialing_price)]))

      allow(Stripe::Subscription).to receive(:list)
        .with(hash_including(status: "trialing"))
        .and_return(double("List", data: [trialing_sub], has_more: false))

      result = described_class.call
      expect(result[:active_subscriptions]).to eq(3)
    end
  end

  describe "Stripe error handling" do
    before do
      allow(Stripe::Subscription).to receive(:list)
        .and_raise(Stripe::APIError.new("Service unavailable"))
    end

    it "returns a fallback response with nil values" do
      result = described_class.call
      expect(result[:active_subscriptions]).to be_nil
      expect(result[:mrr_cents]).to be_nil
      expect(result[:error]).to include("Service unavailable")
      expect(result[:source]).to eq("stripe")
    end
  end

  describe "pagination" do
    let(:page1) do
      double("List", data: [monthly_sub], has_more: true)
    end

    let(:page2) do
      double("List", data: [yearly_sub], has_more: false)
    end

    before do
      call_count = 0
      allow(Stripe::Subscription).to receive(:list)
        .with(hash_including(status: "active")) do
          call_count += 1
          call_count == 1 ? page1 : page2
        end
    end

    it "fetches all pages of active subscriptions" do
      result = described_class.call
      expect(result[:active_subscriptions]).to eq(2)
    end
  end

  private

  def stub_rails_cache
    allow(Rails.cache).to receive(:fetch) do |_key, **_opts, &block|
      block.call
    end
  end
end
