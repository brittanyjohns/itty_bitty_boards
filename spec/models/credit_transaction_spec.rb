require "rails_helper"

RSpec.describe CreditTransaction, type: :model do
  let(:user) { FactoryBot.create(:user) }

  it "validates kind inclusion" do
    t = described_class.new(user: user, amount: 1, kind: "bogus", source: "plan")
    expect(t).not_to be_valid
    expect(t.errors[:kind]).to be_present
  end

  it "validates source inclusion" do
    t = described_class.new(user: user, amount: 1, kind: "plan_grant", source: "wallet")
    expect(t).not_to be_valid
    expect(t.errors[:source]).to be_present
  end

  it "enforces unique stripe_event_id when present" do
    described_class.create!(user: user, amount: 5, kind: "topup_purchase", source: "topup", stripe_event_id: "evt_unique")
    dup = described_class.new(user: user, amount: 5, kind: "topup_purchase", source: "topup", stripe_event_id: "evt_unique")
    expect(dup).not_to be_valid
  end

  it "allows multiple rows with no stripe_event_id" do
    described_class.create!(user: user, amount: -1, kind: "spend", source: "plan", feature_key: "word_suggestion")
    second = described_class.new(user: user, amount: -1, kind: "spend", source: "plan", feature_key: "word_suggestion")
    expect(second).to be_valid
  end

  describe "scopes" do
    before do
      described_class.create!(user: user, amount: 100, kind: "plan_grant", source: "plan", expires_at: 30.days.from_now)
      described_class.create!(user: user, amount: 50, kind: "topup_purchase", source: "topup")
      described_class.create!(user: user, amount: -3, kind: "spend", source: "plan", feature_key: "image_edit")
    end

    it "spends returns only spend rows" do
      expect(described_class.spends.count).to eq(1)
    end

    it "grants returns positive non-spend rows" do
      expect(described_class.grants.count).to eq(2)
    end

    it "plan/topup scope by source" do
      expect(described_class.plan.count).to eq(2)
      expect(described_class.topup.count).to eq(1)
    end
  end
end
