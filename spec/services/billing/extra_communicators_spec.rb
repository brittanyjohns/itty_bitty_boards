require "rails_helper"

RSpec.describe Billing::ExtraCommunicators do
  around do |example|
    keys = %w[
      STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY
      STRIPE_PRICE_PRO_EXTRA_COMM_YEARLY
      STRIPE_PRICE_PRO_EXTRA_COMM_5YR
      MAX_EXTRA_COMMUNICATORS
    ]
    saved = keys.index_with { |k| ENV[k] }
    example.run
    saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  describe ".clamp" do
    it "coerces nil/blank to 0 and floors negatives at 0" do
      expect(described_class.clamp(nil)).to eq(0)
      expect(described_class.clamp("")).to eq(0)
      expect(described_class.clamp(-4)).to eq(0)
    end

    it "passes through in-range values" do
      expect(described_class.clamp("3")).to eq(3)
      expect(described_class.clamp(5)).to eq(5)
    end

    it "caps at the configured max" do
      ENV["MAX_EXTRA_COMMUNICATORS"] = "7"
      expect(described_class.clamp(999)).to eq(7)
    end
  end

  describe ".price_id / .recurring_price_id" do
    it "resolves configured prices and returns nil when unset" do
      ENV["STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY"] = "price_m"
      ENV["STRIPE_PRICE_PRO_EXTRA_COMM_YEARLY"] = "price_y"
      ENV.delete("STRIPE_PRICE_PRO_EXTRA_COMM_5YR")

      expect(described_class.price_id("monthly")).to eq("price_m")
      expect(described_class.recurring_price_id("yearly")).to eq("price_y")
      expect(described_class.recurring_price_id("anything_else")).to eq("price_m")
      expect(described_class.price_id("license")).to be_nil
    end
  end

  describe ".extra_comm_item? / .quantity_from_subscription" do
    def item(price_id: nil, kind: nil, quantity: 1)
      meta = kind ? { "kind" => kind } : {}
      OpenStruct.new(quantity: quantity, price: OpenStruct.new(id: price_id, metadata: meta))
    end

    it "matches by configured price id" do
      ENV["STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY"] = "price_extra_m"
      expect(described_class.extra_comm_item?(item(price_id: "price_extra_m"))).to be(true)
      expect(described_class.extra_comm_item?(item(price_id: "price_pro"))).to be(false)
    end

    it "matches by metadata tag even when no price id is configured" do
      ENV.delete("STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY")
      ENV.delete("STRIPE_PRICE_PRO_EXTRA_COMM_YEARLY")
      ENV.delete("STRIPE_PRICE_PRO_EXTRA_COMM_5YR")
      expect(described_class.extra_comm_item?(item(kind: "extra_communicator"))).to be(true)
      expect(described_class.extra_comm_item?(item(kind: "plan"))).to be(false)
    end

    it "sums extra-comm quantities across a subscription, ignoring the plan item" do
      ENV["STRIPE_PRICE_PRO_EXTRA_COMM_MONTHLY"] = "price_extra_m"
      sub = OpenStruct.new(items: OpenStruct.new(data: [
        item(price_id: "price_pro", quantity: 1),                 # plan item — ignored
        item(price_id: "price_extra_m", quantity: 3),             # add-on
      ]))
      expect(described_class.quantity_from_subscription(sub)).to eq(3)
    end

    it "returns 0 for a subscription with no add-on item" do
      sub = OpenStruct.new(items: OpenStruct.new(data: [item(price_id: "price_pro", quantity: 1)]))
      expect(described_class.quantity_from_subscription(sub)).to eq(0)
      expect(described_class.quantity_from_subscription(nil)).to eq(0)
    end
  end
end
