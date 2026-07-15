require "rails_helper"

# Covers the new 5-Year license (basic_5yr / pro_5yr) and clinician plan types:
# predicates, limits (setup_limits), board_group_limit, and monthly credit
# amounts.
RSpec.describe User, "5-Year license + clinician plan types", type: :model do
  describe "basic_5yr" do
    let(:user) { FactoryBot.create(:user, plan_type: "basic_5yr") }

    it "is treated as Basic and paid" do
      expect(user.basic?).to be(true)
      expect(user.pro?).to be(false)
      expect(user.paid_plan?).to be(true)
    end

    it "gets Basic limits" do
      expect(user.settings["board_limit"]).to eq(User::BASIC_PLAN_LIMITS["board_limit"])
      expect(user.settings["paid_communicator_limit"]).to eq(User::BASIC_PLAN_LIMITS["paid_communicator_limit"])
      expect(user.board_group_limit).to eq(User::BASIC_PLAN_LIMITS["board_group_limit"])
    end

    it "has the Basic monthly credit amount" do
      expect(CreditService.monthly_credits_for("basic_5yr")).to eq(400)
    end
  end

  describe "pro_5yr" do
    let(:user) { FactoryBot.create(:user, plan_type: "pro_5yr") }

    it "is treated as Pro and paid" do
      expect(user.pro?).to be(true)
      expect(user.paid_plan?).to be(true)
    end

    it "gets Pro limits" do
      expect(user.settings["board_limit"]).to eq(User::PRO_PLAN_LIMITS["board_limit"])
      expect(user.settings["paid_communicator_limit"]).to eq(User::PRO_PLAN_LIMITS["paid_communicator_limit"])
      expect(user.board_group_limit).to eq(User::PRO_PLAN_LIMITS["board_group_limit"])
    end

    it "has the Pro monthly credit amount" do
      expect(CreditService.monthly_credits_for("pro_5yr")).to eq(1500)
    end
  end

  describe "clinician" do
    let(:user) { FactoryBot.create(:user, plan_type: "clinician") }

    it "is paid but NOT Pro (the 2-slot loaner cap is the product)" do
      expect(user.clinician?).to be(true)
      expect(user.paid_plan?).to be(true)
      expect(user.pro?).to be(false)
      expect(user.professional?).to be(false)
    end

    it "gets clinician limits (300 boards / 50 groups / 2 loaner / 2 sandbox)" do
      expect(user.settings["board_limit"]).to eq(300)
      expect(user.settings["paid_communicator_limit"]).to eq(2)
      expect(user.settings["demo_communicator_limit"]).to eq(2)
      expect(user.board_group_limit).to eq(50)
    end

    it "has 400 monthly credits" do
      expect(CreditService.monthly_credits_for("clinician")).to eq(400)
    end
  end
end
