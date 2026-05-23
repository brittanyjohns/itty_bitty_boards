# frozen_string_literal: true

require "rails_helper"

# Issue #159 (B3) — sandbox → loaner mints a passcode by default so a
# child can sign in, but passcodes are optional at every status: callers
# may create or save a loaner/active without one, and a sandbox may
# carry one (no validation enforces either rule).
RSpec.describe ChildAccount, "loaner provisioning", type: :model do
  let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

  describe "passcode is optional regardless of status" do
    it "saves a loaner without a passcode" do
      account = build(:child_account, user: user, status: "loaner", passcode: nil)
      expect(account).to be_valid
    end

    it "saves an active without a passcode" do
      account = build(:child_account, user: user, status: "active", passcode: nil)
      expect(account).to be_valid
    end

    it "saves a sandbox with a passcode" do
      account = build(:child_account, user: user, status: "sandbox", passcode: "anything")
      expect(account).to be_valid
    end
  end

  describe "#promote_to_loaner!" do
    let(:account) { create(:child_account, user: user, status: "sandbox", passcode: nil) }

    it "flips status to loaner and provisions a passcode" do
      expect { account.promote_to_loaner! }.to change { account.status }.from("sandbox").to("loaner")
      expect(account.passcode).to be_present
    end

    it "honors a caller-supplied passcode" do
      account.promote_to_loaner!(passcode: "chosenpass")
      expect(account.passcode).to eq("chosenpass")
    end

    it "lifts the sandbox board cap" do
      account.update!(settings: { "demo_board_limit" => 1 })
      account.promote_to_loaner!
      expect(account.settings).not_to have_key("demo_board_limit")
    end

    it "is idempotent on a loaner" do
      account.promote_to_loaner!
      expect { account.promote_to_loaner! }.not_to change { account.reload.status }
    end

    it "refuses to demote an active back to loaner" do
      account.update!(status: "loaner", passcode: "x")
      account.update!(status: "active")
      expect { account.promote_to_loaner! }.to raise_error(ArgumentError)
    end
  end
end
