require "rails_helper"

RSpec.describe Billing::DeclineReason do
  describe ".for" do
    it "maps insufficient_funds" do
      expect(described_class.for(code: "card_declined", decline_code: "insufficient_funds"))
        .to eq("insufficient_funds")
    end

    it "maps expired_card" do
      expect(described_class.for(code: "expired_card")).to eq("expired_card")
    end

    it "maps every card-detail code to incorrect_details" do
      %w[incorrect_cvc invalid_cvc incorrect_number invalid_number
        invalid_expiry_month invalid_expiry_year incorrect_zip].each do |code|
        expect(described_class.for(code: code)).to eq("incorrect_details"), "#{code} should be incorrect_details"
      end
    end

    it "maps every issuer-decline code to bank_declined" do
      %w[generic_decline do_not_honor call_issuer transaction_not_allowed
        service_not_allowed card_not_supported currency_not_supported
        try_again_later processing_error issuer_not_available
        reenter_transaction revocation_of_authorization].each do |code|
        expect(described_class.for(code: "card_declined", decline_code: code))
          .to eq("bank_declined"), "#{code} should be bank_declined"
      end
    end

    # The whole point of the mapping: a fraud flag is never surfaced. It tips
    # off a real fraudster, and it fires as a false positive on legitimate
    # customers who must not be told their card was reported stolen.
    it "maps every fraud code to generic" do
      expect(described_class::FRAUD_CODES).not_to be_empty

      described_class::FRAUD_CODES.each do |code|
        expect(described_class.for(code: "card_declined", decline_code: code))
          .to eq("generic"), "#{code} must not be surfaced"
        expect(described_class.for(code: code)).to eq("generic"), "#{code} must not be surfaced"
      end
    end

    it "never surfaces a fraud code under its own name" do
      surfaced = described_class::MAPPING.keys & described_class::FRAUD_CODES
      expect(surfaced).to be_empty
    end

    # v1: its CTA is a 3DS confirmation at hosted_invoice_url, which we do not
    # store, so naming the reason would point the user somewhere useless.
    it "folds authentication_required into generic for now" do
      expect(described_class.for(code: "authentication_required")).to eq("generic")
    end

    it "fails closed to generic for unknown, blank and nil codes" do
      expect(described_class.for(code: "card_declined", decline_code: "82")).to eq("generic")
      expect(described_class.for(code: "some_new_stripe_code")).to eq("generic")
      expect(described_class.for(code: nil, decline_code: nil)).to eq("generic")
      expect(described_class.for(code: "", decline_code: "  ")).to eq("generic")
      expect(described_class.for).to eq("generic")
    end

    it "prefers the specific decline_code over the generic code" do
      expect(described_class.for(code: "card_declined", decline_code: "expired_card"))
        .to eq("expired_card")
    end

    it "falls back to code when decline_code is unrecognized" do
      expect(described_class.for(code: "expired_card", decline_code: "82")).to eq("expired_card")
    end

    it "is case and whitespace insensitive" do
      expect(described_class.for(decline_code: " Insufficient_Funds ")).to eq("insufficient_funds")
    end
  end
end
