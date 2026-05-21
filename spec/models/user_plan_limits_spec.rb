# frozen_string_literal: true

require "rails_helper"

RSpec.describe User, "plan limit constants", type: :model do
  describe "demo communicator limits" do
    # Demo communicator accounts are intended for Pro only (1 account).
    # Defaults are read from ENV at class load; with the ENV vars unset
    # (the test environment) these reflect the in-code defaults.
    it "grants demo communicator accounts to Pro only" do
      expect(User::FREE_PLAN_LIMITS["demo_communicator_limit"]).to eq(0)
      expect(User::MYSPEAK_PLAN_LIMITS["demo_communicator_limit"]).to eq(0)
      expect(User::BASIC_PLAN_LIMITS["demo_communicator_limit"]).to eq(0)
      expect(User::PRO_PLAN_LIMITS["demo_communicator_limit"]).to eq(1)
    end
  end
end
