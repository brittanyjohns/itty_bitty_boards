require "rails_helper"

# Downgrade fallback mode for over-limit communicators (issue #255).
# When a paid account drops to Free, communicators beyond the Free slot limit
# are retained (boards + MySpeak + public_url intact) but flagged "fallback":
# private passcode sign-in is blocked while the public page stays open. On
# re-upgrade the flag clears, most-recently-active first.
RSpec.describe "Communicator fallback mode (#255)", type: :model do
  # Build a paid (Pro) owner with `count` active communicators, each stamped
  # with a distinct last_sign_in_at so the keep/flag ordering is deterministic.
  def pro_owner_with_active(count)
    owner = FactoryBot.create(:user)
    owner.update!(plan_type: "pro") # Pro slot limit = 5
    accounts = Array.new(count) do |i|
      acct = FactoryBot.create(:child_account, user: owner, status: ChildAccount::ACTIVE,
                                                username: "comm_#{owner.id}_#{i}")
      # Earlier index => more recent sign-in, so index 0 is "most recently active".
      acct.update_column(:last_sign_in_at, (i + 1).hours.ago)
      acct
    end
    [owner, accounts]
  end

  describe "ChildAccount fallback marker" do
    let(:account) { FactoryBot.create(:child_account, status: ChildAccount::ACTIVE) }

    it "is not in fallback mode by default" do
      expect(account.fallback_mode?).to be(false)
    end

    it "enter_fallback! sets the marker, reason, and timestamp" do
      account.enter_fallback!
      expect(account.fallback_mode?).to be(true)
      expect(account.settings["fallback_reason"]).to eq("downgrade")
      expect(account.settings["fallback_since"]).to be_present
    end

    it "exit_fallback! clears the marker and its metadata" do
      account.enter_fallback!
      account.exit_fallback!
      expect(account.fallback_mode?).to be(false)
      expect(account.settings).not_to have_key("fallback_since")
      expect(account.settings).not_to have_key("fallback_reason")
    end

    it "enter_fallback! is idempotent" do
      account.enter_fallback!
      since = account.settings["fallback_since"]
      account.enter_fallback!
      expect(account.settings["fallback_since"]).to eq(since)
    end
  end

  describe "ChildAccount#can_sign_in?" do
    it "returns false for a fallback communicator owned by a normal user" do
      owner = FactoryBot.create(:user)
      owner.update!(plan_type: "pro")
      account = FactoryBot.create(:child_account, user: owner, status: ChildAccount::ACTIVE)
      account.enter_fallback!
      expect(account.can_sign_in?).to be(false)
    end

    it "still lets a system admin sign in to a fallback communicator (support access)" do
      admin = FactoryBot.create(:admin_user)
      account = FactoryBot.create(:child_account, user: admin, status: ChildAccount::ACTIVE)
      account.enter_fallback!
      expect(account.can_sign_in?(admin)).to be(true)
    end
  end

  describe "User#reconcile_communicator_fallback!" do
    it "keeps everything signable while within the slot limit" do
      _owner, accounts = pro_owner_with_active(3)
      expect(accounts.map(&:reload).map(&:fallback_mode?)).to all(be(false))
    end

    it "on downgrade to Free, keeps the most-recently-active and flags the overflow" do
      owner, accounts = pro_owner_with_active(3)

      owner.update!(plan_type: "free") # Free slot limit = 1, fires reconcile

      kept, *overflow = accounts.map(&:reload)
      expect(kept.fallback_mode?).to be(false)            # most recently active
      expect(overflow.map(&:fallback_mode?)).to all(be(true))
    end

    it "retains the over-limit communicators on downgrade (never deletes them)" do
      owner, accounts = pro_owner_with_active(3)
      owner.update!(plan_type: "free")
      expect(ChildAccount.where(id: accounts.map(&:id)).count).to eq(3)
    end

    it "on re-upgrade restores fallback communicators most-recently-active first" do
      owner, accounts = pro_owner_with_active(3)
      owner.update!(plan_type: "free")  # limit 1: keep #0, flag #1 and #2

      owner.update!(plan_type: "basic") # limit 2: restore one more (the next most recent)

      a0, a1, a2 = accounts.map(&:reload)
      expect(a0.fallback_mode?).to be(false)
      expect(a1.fallback_mode?).to be(false) # restored (more recently active than a2)
      expect(a2.fallback_mode?).to be(true)  # still over the Basic limit of 2
    end

    it "fully restores everyone when the plan can cover all communicators again" do
      owner, accounts = pro_owner_with_active(3)
      owner.update!(plan_type: "free")
      owner.update!(plan_type: "pro") # limit 5 covers all 3
      expect(accounts.map(&:reload).map(&:fallback_mode?)).to all(be(false))
    end
  end

  describe "owner-chosen keep set (#439)" do
    it "keeps the owner's pinned communicator signable over a more-recently-active one" do
      owner, (a0, a1, a2) = pro_owner_with_active(3)
      owner.update!(plan_type: "basic") # limit 2: default keeps a0, a1; a2 falls back
      expect(a2.reload.fallback_mode?).to be(true)

      # Owner overrides: keep a2 (and a0). a1 now falls back instead.
      owner.set_kept_communicator_ids!([a2.id, a0.id])

      expect(a2.reload.fallback_mode?).to be(false)
      expect(a0.reload.fallback_mode?).to be(false)
      expect(a1.reload.fallback_mode?).to be(true)
    end

    it "caps the pinned set at the plan slot limit, keeping the order sent" do
      owner, (a0, a1, a2) = pro_owner_with_active(3)
      owner.update!(plan_type: "basic") # limit 2

      kept = owner.set_kept_communicator_ids!([a2.id, a1.id, a0.id])

      expect(kept).to eq([a2.id, a1.id])      # third pick dropped (over limit)
      expect(a0.reload.fallback_mode?).to be(true)
    end

    it "ignores ids the caller does not own" do
      owner, (a0, _a1, _a2) = pro_owner_with_active(3)
      owner.update!(plan_type: "basic")
      stranger = FactoryBot.create(:child_account, status: ChildAccount::ACTIVE)

      kept = owner.set_kept_communicator_ids!([a0.id, stranger.id])

      expect(kept).to eq([a0.id])
    end

    it "reverts to the most-recently-active rule when the pick is cleared" do
      owner, (a0, a1, a2) = pro_owner_with_active(3)
      owner.update!(plan_type: "basic")
      owner.set_kept_communicator_ids!([a2.id])   # pin the least-recent
      expect(a2.reload.fallback_mode?).to be(false)

      owner.set_kept_communicator_ids!([])         # clear the pick

      expect(a0.reload.fallback_mode?).to be(false) # recency again
      expect(a1.reload.fallback_mode?).to be(false)
      expect(a2.reload.fallback_mode?).to be(true)
    end

    it "surfaces the slot limit and kept ids on the user api_view" do
      owner, (a0, _a1, _a2) = pro_owner_with_active(3)
      owner.update!(plan_type: "basic")
      owner.set_kept_communicator_ids!([a0.id])

      view = owner.api_view
      expect(view[:communicator_slot_limit]).to eq(2)
      expect(view[:kept_communicator_ids]).to eq([a0.id])
    end
  end

  describe "new Free signup" do
    it "is capped at 1 communicator and is never flagged into fallback" do
      free_user = FactoryBot.create(:free_user)
      account = FactoryBot.create(:child_account, user: free_user, status: ChildAccount::ACTIVE)
      free_user.reconcile_communicator_fallback!
      expect(account.reload.fallback_mode?).to be(false)
    end
  end

  describe "api_view exposure" do
    it "surfaces fallback_mode so the frontend can redirect vs error" do
      owner = FactoryBot.create(:user)
      owner.update!(plan_type: "pro")
      account = FactoryBot.create(:child_account, user: owner, status: ChildAccount::ACTIVE)
      account.enter_fallback!
      view = account.api_view(owner)
      expect(view[:fallback_mode]).to be(true)
      expect(view[:fallback_since]).to be_present
    end
  end
end
