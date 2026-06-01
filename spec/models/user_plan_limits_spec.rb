# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, "plan limits", type: :model do
  describe "sandbox (legacy demo) communicator limits" do
    # Every Free user gets one sandbox communicator (the MySpeak ID).
    # Pro also gets one. Basic has none.
    it "grants one sandbox communicator to Free and Pro, none to Basic" do
      expect(User::FREE_PLAN_LIMITS["demo_communicator_limit"]).to eq(1)
      expect(User::BASIC_PLAN_LIMITS["demo_communicator_limit"]).to eq(0)
      expect(User::PRO_PLAN_LIMITS["demo_communicator_limit"]).to eq(1)
    end

    it "no longer defines a MySpeak plan tier" do
      expect(defined?(User::MYSPEAK_PLAN_LIMITS)).to be_nil
    end
  end

  # Slot pool sizes (self-created or claimed):
  #   Free  — 1.
  #   Basic — 2.
  #   Pro   — 5.  (Bumped from 3 on 2026-05-31; see pricing-structure.md.)
  describe "paid (loaner+active) communicator slot limits" do
    it "matches the locked slot math from the spec" do
      expect(User::FREE_PLAN_LIMITS["paid_communicator_limit"]).to eq(1)
      expect(User::BASIC_PLAN_LIMITS["paid_communicator_limit"]).to eq(2)
      expect(User::PRO_PLAN_LIMITS["paid_communicator_limit"]).to eq(5)
    end
  end

  describe "#setup_free_limits" do
    it "seeds the free-tier slot math (1 sandbox + 1 claimable)" do
      user = build(:user)
      user.setup_free_limits

      expect(user.settings["demo_communicator_limit"]).to eq(1)
      expect(user.settings["board_limit"]).to eq(1)
      expect(user.settings["paid_communicator_limit"]).to eq(1)
      expect(user.settings["ai_monthly_limit"]).to eq(5)
    end
  end

  describe "#has_myspeak_feature?" do
    it "is true when the user has a sandbox communicator slot" do
      user = build(:user, settings: { "demo_communicator_limit" => 1 })
      expect(user.has_myspeak_feature?).to be(true)
    end

    it "is false when the user has no sandbox communicator slot" do
      user = build(:user, settings: { "demo_communicator_limit" => 0 })
      expect(user.has_myspeak_feature?).to be(false)
    end
  end
end
