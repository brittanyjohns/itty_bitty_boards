require "rails_helper"

# The shared arithmetic — cap, topup-first split, (reason, image_id)
# idempotency — is exercised end to end through Menus::CreditRefunds, which
# delegates here. This file covers what only this class answers: which txn it
# will act on, and that it can never raise into a calling job.
RSpec.describe Credits::TxnRefunds do
  let(:user) { FactoryBot.create(:user) }
  let!(:txn) do
    CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
    CreditService.spend!(user, feature_key: "image_generation", amount: 9)
  end

  describe ".spend_txn" do
    it "finds the spend it is given" do
      expect(described_class.spend_txn(txn.id)).to eq(txn)
    end

    it "is nil for a blank id" do
      expect(described_class.spend_txn(nil)).to be_nil
      expect(described_class.spend_txn("")).to be_nil
    end

    it "is nil for an id that names no row" do
      expect(described_class.spend_txn(txn.id + 10_000)).to be_nil
    end

    # A refund row's id must never be mistaken for the spend it reverses.
    it "is nil for a transaction that is not a spend" do
      refund = CreditService.refund!(user, amount: 1, feature_key: "image_generation")
      expect(described_class.spend_txn(refund.id)).to be_nil
    end
  end

  describe ".refund!" do
    it "returns the amount it refunded" do
      expect(described_class.refund!(txn, 3, reason: "x")).to eq(3)
    end

    it "no-ops without a transaction" do
      expect {
        expect(described_class.refund!(nil, 3, reason: "x")).to eq(0)
      }.not_to change { user.reload.plan_credits_balance }
    end

    it "no-ops for a non-positive amount" do
      expect {
        expect(described_class.refund!(txn, 0, reason: "x")).to eq(0)
      }.not_to change { user.reload.plan_credits_balance }
    end

    it "carries the caller's own context onto the refund row" do
      described_class.refund!(txn, 3, reason: "x", image_id: 7, metadata: { board_id: 42 })

      meta = CreditTransaction.where(kind: "refund").last.metadata
      expect(meta).to include("board_id" => 42, "refund_for_txn" => txn.id,
                              "refund_reason" => "x", "image_id" => 7)
    end

    # A raise here fires AFTER the work it is reconciling, so it would turn a
    # completed generation into a Sidekiq retry — and generate the image twice.
    it "logs and returns 0 rather than raising into the caller" do
      allow(CreditService).to receive(:refund!).and_raise("ledger down")
      expect(Rails.logger).to receive(:error).with(/Credits::TxnRefunds/)

      expect { expect(described_class.refund!(txn, 3, reason: "x")).to eq(0) }.not_to raise_error
    end
  end
end
