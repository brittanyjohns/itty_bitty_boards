# frozen_string_literal: true

require "rails_helper"

# Issue #159 (B3) — sandbox → loaner adds a working login and lifts the
# sandbox board cap. Login validations are repaired against status.
RSpec.describe ChildAccount, "loaner provisioning", type: :model do
  let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

  describe "login validations" do
    it "rejects a new loaner without a passcode" do
      account = build(:child_account, user: user, status: "loaner", passcode: nil)
      expect(account).not_to be_valid
      expect(account.errors[:passcode]).to be_present
    end

    it "rejects a new active without a passcode" do
      account = build(:child_account, user: user, status: "active", passcode: nil)
      expect(account).not_to be_valid
    end

    it "rejects setting a passcode on a brand-new sandbox" do
      account = build(:child_account, user: user, status: "sandbox", passcode: "secret123")
      expect(account).not_to be_valid
      expect(account.errors[:passcode]).to be_present
    end

    it "leaves legacy sandbox-with-passcode rows alone until status is changed" do
      account = create(:child_account, user: user, status: "sandbox", passcode: nil)
      # Sneak a passcode into a legacy sandbox without going through the writer.
      account.update_column(:passcode, "legacy123")
      account.reload

      account.name = "Edited"
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
