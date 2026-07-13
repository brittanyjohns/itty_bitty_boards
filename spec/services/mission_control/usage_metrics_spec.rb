require "rails_helper"

RSpec.describe MissionControl::UsageMetrics do
  describe ".call" do
    let!(:real_user) { create(:user) }
    let!(:demo_user) { create(:user, email: "bhannajohns+usage@gmail.com") }

    subject(:result) { described_class.call }

    it "excludes demo-owned builder sets" do
      create(:board, user: real_user, settings: { "builder_root" => true })
      create(:board, user: demo_user, settings: { "builder_root" => true })

      expect(result[:builder_sets_30d]).to eq(1)
    end

    it "excludes demo users' credit spends" do
      CreditTransaction.create!(user: real_user, kind: "spend", source: "plan", amount: -5)
      CreditTransaction.create!(user: demo_user, kind: "spend", source: "plan", amount: -7)

      expect(result[:credits_spent_30d]).to eq(5)
    end

    it "excludes demo-owned communicators" do
      create(:child_account, user: real_user)
      create(:child_account, user: demo_user)

      expect(result[:communicators_created_7d]).to eq(1)
    end
  end
end
