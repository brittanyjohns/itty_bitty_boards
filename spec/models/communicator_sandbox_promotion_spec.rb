# frozen_string_literal: true

require "rails_helper"

# Issue #359 — a Free user's self-created communicators are forced to sandbox.
# When the user upgrades to a paid plan, those sandboxes should become full
# `active` communicators (with sign-in), up to the plan's slot limit. Without
# this, a paying Basic user was stuck with a sandbox communicator and "sign-in
# disabled" messaging.
RSpec.describe "Paid sandbox promotion (#359)", type: :model do
  describe "ChildAccount#promote_to_active!" do
    let(:user) { create(:user, plan_type: "basic") }

    it "flips status sandbox -> active and mints a passcode" do
      account = create(:child_account, user: user, status: ChildAccount::SANDBOX, passcode: nil)
      expect { account.promote_to_active! }
        .to change { account.status }.from("sandbox").to("active")
      expect(account.passcode).to be_present
    end

    it "preserves an existing passcode" do
      account = create(:child_account, user: user, status: ChildAccount::SANDBOX, passcode: "keepme12")
      account.promote_to_active!
      expect(account.passcode).to eq("keepme12")
    end

    it "lifts the per-account sandbox board cap" do
      account = create(:child_account, user: user, status: ChildAccount::SANDBOX,
                                       settings: { "demo_board_limit" => 1 })
      account.promote_to_active!
      expect(account.settings).not_to have_key("demo_board_limit")
    end

    it "is idempotent on an already-active account and doesn't rotate its passcode" do
      account = create(:child_account, user: user, status: ChildAccount::ACTIVE, passcode: "active12")
      expect { account.promote_to_active! }.not_to change { account.reload.status }
      expect(account.passcode).to eq("active12")
    end

    it "never demotes a loaner" do
      account = create(:child_account, user: user, status: ChildAccount::LOANER, passcode: "loaner12")
      account.promote_to_active!
      expect(account.status).to eq("loaner")
    end
  end

  describe "User#reconcile_paid_sandbox_promotions! on upgrade" do
    # Build a Free owner with `count` sandbox communicators, each stamped with a
    # distinct last_sign_in_at so the promotion ordering is deterministic
    # (index 0 = most recently active).
    def free_owner_with_sandboxes(count)
      owner = create(:user, plan_type: "free")
      accounts = Array.new(count) do |i|
        acct = create(:child_account, user: owner, status: ChildAccount::SANDBOX,
                                      passcode: nil, username: "comm_#{owner.id}_#{i}")
        acct.update_column(:last_sign_in_at, (i + 1).hours.ago)
        acct
      end
      [owner, accounts]
    end

    it "promotes a Free user's sandbox to active when they upgrade to Basic" do
      owner, accounts = free_owner_with_sandboxes(1)
      account = accounts.first

      owner.update!(plan_type: "basic") # fires the callback

      account.reload
      expect(account.status).to eq("active")
      expect(account.passcode).to be_present
    end

    it "promotes only up to the available paid slots, most-recently-active first" do
      owner, accounts = free_owner_with_sandboxes(3)

      owner.update!(plan_type: "basic") # Basic slot limit = 2

      a0, a1, a2 = accounts.map(&:reload)
      expect(a0.status).to eq("active") # most recently active
      expect(a1.status).to eq("active")
      expect(a2.status).to eq("sandbox") # over the Basic limit of 2
    end

    it "accounts for slots already occupied by existing active communicators" do
      owner, sandboxes = free_owner_with_sandboxes(2)
      create(:child_account, user: owner, status: ChildAccount::ACTIVE,
                             passcode: "existing", username: "comm_#{owner.id}_active")

      owner.update!(plan_type: "basic") # limit 2, one slot already taken

      statuses = sandboxes.map { |s| s.reload.status }
      expect(statuses).to contain_exactly("active", "sandbox")
    end

    it "does nothing while the user stays on Free" do
      owner, accounts = free_owner_with_sandboxes(1)
      owner.reconcile_paid_sandbox_promotions!
      expect(accounts.first.reload.status).to eq("sandbox")
    end

    it "is a no-op for admins (unlimited; already sign in to any account)" do
      admin = create(:admin_user)
      account = create(:child_account, user: admin, status: ChildAccount::SANDBOX, passcode: nil)
      admin.reconcile_paid_sandbox_promotions!
      expect(account.reload.status).to eq("sandbox")
    end

    it "is idempotent — re-running promotes nothing new" do
      owner, _accounts = free_owner_with_sandboxes(1)
      owner.update!(plan_type: "basic")
      expect { owner.reconcile_paid_sandbox_promotions! }
        .not_to change { owner.communicator_accounts.where(status: ChildAccount::SANDBOX).count }
    end
  end
end
