# frozen_string_literal: true

require "rails_helper"

# Issue #160 (B4) — SLP → parent claim hand-off.
RSpec.describe ChildAccount, "claim flow", type: :model do
  let(:slp) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:parent) do
    u = create(:user, created_at: 2.months.ago)
    u.setup_free_limits
    u.save!
    u
  end
  let!(:loaner) do
    account = create(:child_account, user: slp, owner: slp, status: "loaner", passcode: "loaner01")
    account.ensure_team!(creator: slp)
    account
  end

  describe "#generate_claim_token!" do
    it "issues a token and timestamp" do
      token = loaner.generate_claim_token!
      expect(token).to be_present
      expect(loaner.claim_token).to eq(token)
      expect(loaner.claim_token_sent_at).to be_within(5.seconds).of(Time.current)
    end

    it "refuses on a sandbox" do
      sandbox = create(:child_account, user: slp, owner: slp, status: "sandbox")
      expect { sandbox.generate_claim_token! }.to raise_error(ArgumentError)
    end
  end

  describe "#claim_by!" do
    it "transfers ownership, frees the SLP slot, keeps SLP as supervisor" do
      loaner.claim_by!(user: parent)

      expect(loaner.status).to eq("active")
      expect(loaner.owner_id).to eq(parent.id)
      expect(loaner.user_id).to eq(parent.id)
      expect(loaner.claimed_at).to be_present
      expect(loaner.claim_token).to be_nil

      # SLP's slot freed
      expect(slp.communicator_accounts.where(status: ["loaner", "active"]).count).to eq(0)
      # Parent now holds it
      expect(parent.communicator_accounts.where(status: "active").count).to eq(1)
      # SLP still linked as supervisor on the team
      team = loaner.reload.primary_team
      slp_membership = team.team_users.find_by(user_id: slp.id)
      expect(slp_membership.role).to eq("supervisor")
    end

    # The hand-off is where the SLP's credential access ends.
    it "rotates the passcode the SLP knew" do
      loaner.claim_by!(user: parent)
      expect(loaner.reload.passcode).to be_present
      expect(loaner.passcode).not_to eq("loaner01")
    end

    it "uses a passcode the family chose" do
      loaner.claim_by!(user: parent, passcode: "family-pick")
      expect(loaner.reload.passcode).to eq("family-pick")
    end

    # A communicator session IS the authentication_token, so rotating only the
    # passcode would leave the SLP's signed-in devices signed in.
    it "regenerates the session token, ending every earlier session" do
      old_token = loaner.authentication_token
      loaner.claim_by!(user: parent)
      expect(loaner.reload.authentication_token).to be_present
      expect(loaner.authentication_token).not_to eq(old_token)
      expect(ChildAccount.find_by_token(old_token)).to be_nil
    end

    it "leaves the passcode and token alone when the claim is refused" do
      create(:child_account, user: parent, owner: parent, status: "active", passcode: "x", username: "held")
      old_token = loaner.authentication_token
      expect { loaner.claim_by!(user: parent) }.to raise_error(ChildAccount::SlotFull)
      expect(loaner.reload.passcode).to eq("loaner01")
      expect(loaner.authentication_token).to eq(old_token)
    end

    it "raises SlotFull when the parent has no claim slot" do
      # Parent already hosts one — Free hosts exactly 1 claimed.
      create(:child_account, user: parent, owner: parent, status: "active", passcode: "x", username: "first")

      expect { loaner.claim_by!(user: parent) }.to raise_error(ChildAccount::SlotFull)
      expect(loaner.reload.status).to eq("loaner")
    end

    it "refuses to claim a non-loaner" do
      sandbox = create(:child_account, user: slp, owner: slp, status: "sandbox")
      expect { sandbox.claim_by!(user: parent) }.to raise_error(ArgumentError)
    end
  end

  describe "#reclaim!" do
    it "flips loaner back to sandbox and clears the passcode" do
      loaner.reclaim!
      expect(loaner.status).to eq("sandbox")
      expect(loaner.passcode).to be_nil
      expect(loaner.reclaimed_at).to be_present
    end

    it "refuses on an active account" do
      loaner.claim_by!(user: parent)
      expect { loaner.reclaim! }.to raise_error(ArgumentError)
    end
  end
end
