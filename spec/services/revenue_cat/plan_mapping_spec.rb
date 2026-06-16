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

    it "resolves the real reverse-DNS App Store product ids via the fallback" do
      # These are the ids Apple/RevenueCat actually send; the entitlement path is
      # the primary signal, but the product fallback must work when it's absent.
      expect(described_class.resolve_plan_type(product_id: "com.speakanyway.basic.monthly")).to eq("basic")
      expect(described_class.resolve_plan_type(product_id: "com.speakanyway.basic.yearly")).to eq("basic")
      expect(described_class.resolve_plan_type(product_id: "com.speakanyway.pro.monthly")).to eq("pro")
      expect(described_class.resolve_plan_type(product_id: "com.speakanyway.pro.yearly")).to eq("pro")
    end

    it "does NOT map MySpeak products (separate feature, not a plan tier)" do
      expect(Rails.logger).to receive(:warn).with(/could not resolve/)
      expect(described_class.resolve_plan_type(product_id: "com.speakanyway.myspeak.monthly")).to be_nil
    end

    it "returns nil (and logs) when nothing maps" do
      expect(Rails.logger).to receive(:warn).with(/could not resolve/)
      expect(described_class.resolve_plan_type(entitlement_ids: ["mystery"], product_id: "unknown")).to be_nil
    end
  end

  describe ".billing_interval_for_product" do
    it "maps the bare package ids to monthly/yearly" do
      expect(described_class.billing_interval_for_product("pro_monthly")).to eq("monthly")
      expect(described_class.billing_interval_for_product("basic_yearly")).to eq("yearly")
      expect(described_class.billing_interval_for_product("unknown")).to be_nil
    end

    it "maps the real reverse-DNS App Store product ids to monthly/yearly" do
      expect(described_class.billing_interval_for_product("com.speakanyway.pro.monthly")).to eq("monthly")
      expect(described_class.billing_interval_for_product("com.speakanyway.basic.yearly")).to eq("yearly")
      expect(described_class.billing_interval_for_product("com.speakanyway.pro.yearly")).to eq("yearly")
    end
  end
end
