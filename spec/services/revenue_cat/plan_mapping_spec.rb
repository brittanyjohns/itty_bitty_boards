require "rails_helper"

RSpec.describe RevenueCat::PlanMapping do
  describe ".resolve_plan_type" do
    it "prefers the entitlement id over the product id" do
      expect(described_class.resolve_plan_type(entitlement_ids: ["pro"], product_id: "basic_monthly")).to eq("pro")
    end

    it "falls back to the product id when no entitlement maps" do
      expect(described_class.resolve_plan_type(entitlement_ids: [], product_id: "basic_yearly")).to eq("basic")
    end

    it "normalizes yearly products to the base plan_type" do
      expect(described_class.resolve_plan_type(product_id: "pro_yearly")).to eq("pro")
    end

    it "returns nil (and logs) when nothing maps" do
      expect(Rails.logger).to receive(:warn).with(/could not resolve/)
      expect(described_class.resolve_plan_type(entitlement_ids: ["mystery"], product_id: "unknown")).to be_nil
    end
  end

  describe ".billing_interval_for_product" do
    it "maps product ids to monthly/yearly" do
      expect(described_class.billing_interval_for_product("pro_monthly")).to eq("monthly")
      expect(described_class.billing_interval_for_product("basic_yearly")).to eq("yearly")
      expect(described_class.billing_interval_for_product("unknown")).to be_nil
    end
  end
end
