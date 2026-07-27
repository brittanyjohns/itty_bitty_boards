# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::PaymentMethods do
  def customer(default_payment_method: nil, default_source: nil)
    OpenStruct.new(
      invoice_settings: OpenStruct.new(default_payment_method: default_payment_method),
      default_source: default_source,
    )
  end

  def subscription(default_payment_method: nil, customer: "cus_123")
    OpenStruct.new(default_payment_method: default_payment_method, customer: customer)
  end

  describe ".on_file?" do
    it "short-circuits true on the subscription-level default without calling Stripe" do
      expect(Stripe::Customer).not_to receive(:retrieve)

      result = described_class.on_file?("cus_123", subscription: subscription(default_payment_method: "pm_sub"))

      expect(result).to be(true)
    end

    it "is true when the customer's invoice_settings default is set" do
      allow(Stripe::Customer).to receive(:retrieve).with("cus_123").and_return(
        customer(default_payment_method: "pm_cust"),
      )

      result = described_class.on_file?("cus_123", subscription: subscription)

      expect(result).to be(true)
    end

    it "is true when only the legacy default_source is set" do
      allow(Stripe::Customer).to receive(:retrieve).with("cus_123").and_return(
        customer(default_source: "card_legacy"),
      )

      result = described_class.on_file?("cus_123", subscription: subscription)

      expect(result).to be(true)
    end

    it "is false when neither the subscription, invoice_settings default, nor default_source is set" do
      allow(Stripe::Customer).to receive(:retrieve).with("cus_123").and_return(customer)

      result = described_class.on_file?("cus_123", subscription: subscription)

      expect(result).to be(false)
    end

    it "accepts an expanded customer object as well as a bare id" do
      allow(Stripe::Customer).to receive(:retrieve).with("cus_expanded").and_return(
        customer(default_payment_method: "pm_cust"),
      )
      expanded_customer = OpenStruct.new(id: "cus_expanded")

      result = described_class.on_file?(expanded_customer, subscription: subscription)

      expect(result).to be(true)
    end

    it "lets a Stripe error propagate instead of swallowing it, so each caller keeps its own fallback" do
      allow(Stripe::Customer).to receive(:retrieve).and_raise(Stripe::APIError.new("boom"))

      expect {
        described_class.on_file?("cus_123", subscription: subscription)
      }.to raise_error(Stripe::APIError, "boom")
    end
  end
end
