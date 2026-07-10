require "rails_helper"

RSpec.describe Menus::CreditRefunds do
  let(:user) { FactoryBot.create(:user) }
  let(:board) { FactoryBot.create(:board, user: user, board_type: "menu") }

  # A menu build spend: flat fee (5) + 10-image budget at 1/credit = 15.
  def reserve!(reserved: 10, per_image: 1, amount: 15)
    txn = CreditService.spend!(user, feature_key: "menu_create", amount: amount)
    board.update!(settings: (board.settings || {}).merge(
      "menu_credit" => { "txn_id" => txn.id, "per_image" => per_image, "reserved" => reserved },
    ))
    txn
  end

  before do
    CreditService.grant_plan!(user, amount: 100, period_end: 30.days.from_now)
  end

  describe ".refund_unused!" do
    it "refunds the un-queued part of the image budget" do
      reserve!
      expect {
        described_class.refund_unused!(board, 4)
      }.to change { user.reload.plan_credits_balance }.by(6)
    end

    it "is idempotent" do
      reserve!
      described_class.refund_unused!(board, 4)
      expect {
        described_class.refund_unused!(board, 4)
      }.not_to change { user.reload.plan_credits_balance }
    end

    it "no-ops when the whole budget was used" do
      reserve!
      expect {
        described_class.refund_unused!(board, 10)
      }.not_to change { user.reload.plan_credits_balance }
    end

    it "no-ops when the board has no reservation (admin builds, non-menu boards)" do
      expect {
        described_class.refund_unused!(board, 0)
      }.not_to change { user.reload.plan_credits_balance }
    end
  end

  describe ".refund_failed_image!" do
    it "refunds one image cost per failed image, once per image" do
      reserve!
      expect {
        described_class.refund_failed_image!(board, 42)
        described_class.refund_failed_image!(board, 42) # Sidekiq retry
        described_class.refund_failed_image!(board, 43)
      }.to change { user.reload.plan_credits_balance }.by(2)
    end
  end

  describe ".refund_all!" do
    it "refunds the full spend when nothing was delivered" do
      reserve!
      expect {
        described_class.refund_all!(board)
      }.to change { user.reload.plan_credits_balance }.by(15)
    end

    it "caps the total refunded at the original spend" do
      reserve!
      described_class.refund_failed_image!(board, 42)
      expect {
        described_class.refund_all!(board)
      }.to change { user.reload.plan_credits_balance }.by(14)
    end
  end

  describe "topup-first refund split" do
    it "returns topup credits before plan credits, mirroring spend order in reverse" do
      # Drain plan to 3, add 20 topup: a 15-credit spend takes 3 plan + 12 topup.
      user.update!(plan_credits_balance: 3, topup_credits_balance: 20)
      reserve!

      described_class.refund_unused!(board, 0) # refund the 10-credit image budget

      user.reload
      expect(user.topup_credits_balance).to eq(18) # 8 + 10 back to topup first
      expect(user.plan_credits_balance).to eq(0)
    end
  end
end
