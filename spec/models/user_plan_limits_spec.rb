# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, "plan limits", type: :model do
  describe "demo communicator limits" do
    # MySpeak (a demo communicator + public profile) is a free feature: every
    # Free user gets one demo-communicator slot. Pro also gets one.
    it "grants one demo communicator to Free and Pro, none to Basic" do
      expect(User::FREE_PLAN_LIMITS["demo_communicator_limit"]).to eq(1)
      expect(User::BASIC_PLAN_LIMITS["demo_communicator_limit"]).to eq(0)
      expect(User::PRO_PLAN_LIMITS["demo_communicator_limit"]).to eq(1)
    end

    it "no longer defines a MySpeak plan tier" do
      expect(defined?(User::MYSPEAK_PLAN_LIMITS)).to be_nil
    end
  end

  describe "#setup_free_limits" do
    it "gives a free user one demo-communicator slot (the MySpeak ID)" do
      user = build(:user)
      user.setup_free_limits

      expect(user.settings["demo_communicator_limit"]).to eq(1)
      expect(user.settings["board_limit"]).to eq(1)
      expect(user.settings["paid_communicator_limit"]).to eq(0)
      expect(user.settings["ai_monthly_limit"]).to eq(5)
    end
  end

  describe "#has_myspeak_feature?" do
    it "is true when the user has a demo-communicator slot" do
      user = build(:user, settings: { "demo_communicator_limit" => 1 })
      expect(user.has_myspeak_feature?).to be(true)
    end

    it "is false when the user has no demo-communicator slot" do
      user = build(:user, settings: { "demo_communicator_limit" => 0 })
      expect(user.has_myspeak_feature?).to be(false)
    end
  end
end
