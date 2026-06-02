# frozen_string_literal: true

require "rails_helper"

# Issue #165 — soft-archive support for sandbox communicators. Archived
# rows disappear from default-scoped queries, including the slot counts
# that drive sandbox limits.
RSpec.describe ChildAccount, "soft-archive", type: :model do
  let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

  describe "default scope" do
    it "hides archived records from default queries" do
      visible  = create(:child_account, user: user, owner: user, status: "sandbox")
      archived = create(:child_account, user: user, owner: user, status: "sandbox")
      archived.update!(archived_at: Time.current)

      expect(ChildAccount.all).to include(visible)
      expect(ChildAccount.all).not_to include(archived)
    end

    it "exposes archived rows through .archived and .with_archived" do
      visible  = create(:child_account, user: user, owner: user, status: "sandbox")
      archived = create(:child_account, user: user, owner: user, status: "sandbox")
      archived.update!(archived_at: Time.current)

      expect(ChildAccount.archived).to contain_exactly(archived)
      expect(ChildAccount.with_archived).to include(visible, archived)
    end
  end

  describe "association filtering" do
    it "removes archived sandboxes from user.communicator_accounts" do
      a = create(:child_account, user: user, owner: user, status: "sandbox")
      b = create(:child_account, user: user, owner: user, status: "sandbox")
      b.update!(archived_at: Time.current)

      expect(user.communicator_accounts.reload).to contain_exactly(a)
    end
  end

  describe "#archive!" do
    it "stamps archived_at and stays a sandbox" do
      account = create(:child_account, user: user, owner: user, status: "sandbox")
      account.archive!
      expect(account.archived_at).to be_within(5.seconds).of(Time.current)
      expect(account.status).to eq("sandbox")
    end

    it "is idempotent on an already-archived row" do
      account = create(:child_account, user: user, owner: user, status: "sandbox")
      account.archive!
      original = account.archived_at
      account.archive!
      expect(account.archived_at).to eq(original)
    end

    it "preserves boards/settings/details" do
      account = create(:child_account, user: user, owner: user, status: "sandbox",
                                       settings: { "voice" => { "name" => "polly:kevin" } },
                                       details: { "school" => "Lincoln" })
      board = create(:board, user: user)
      create(:child_board, child_account: account, board: board)

      account.archive!
      account.reload
      expect(account.settings["voice"]).to eq({ "name" => "polly:kevin" })
      expect(account.details["school"]).to eq("Lincoln")
      expect(account.child_boards.count).to eq(1)
    end

    it "refuses on a loaner with end_loan guidance" do
      account = create(:child_account, user: user, owner: user, status: "loaner")
      expect { account.archive! }.to raise_error(ArgumentError, /end_loan|reclaim/i)
    end

    it "allows an active owner to archive (issue #237)" do
      account = create(:child_account, user: user, owner: user, status: "active")
      account.archive!
      expect(account.archived_at).to be_within(5.seconds).of(Time.current)
      expect(account.status).to eq("active")
    end

    it "writes archive_reason and archived_status to settings on active archive" do
      account = create(:child_account, user: user, owner: user, status: "active")
      account.archive!(reason: "owner_request")
      expect(account.settings["archive_reason"]).to eq("owner_request")
      expect(account.settings["archived_status"]).to eq("active")
    end
  end

  describe "#unarchive!" do
    it "clears archived_at on a sandbox" do
      account = create(:child_account, user: user, owner: user, status: "sandbox")
      account.archive!
      ChildAccount.with_archived.find(account.id).unarchive!
      expect(account.reload.archived_at).to be_nil
    end

    it "restores an archived active as active when the owner has a free slot" do
      user.setup_pro_limits
      user.save!
      account = create(:child_account, user: user, owner: user, status: "active")
      account.archive!

      ChildAccount.with_archived.find(account.id).unarchive!
      account.reload
      expect(account.archived_at).to be_nil
      expect(account.status).to eq("active")
      expect(account.settings["archive_reason"]).to be_nil
      expect(account.settings["archived_status"]).to be_nil
    end

    it "raises SlotFull when the owner is at the slot cap" do
      user.setup_pro_limits
      user.save!
      pro_limit = user.settings["paid_communicator_limit"]

      account = create(:child_account, user: user, owner: user, status: "active")
      account.archive!

      # Fill every paid slot so unarchive has nowhere to land.
      pro_limit.times { create(:child_account, user: user, owner: user, status: "active") }

      target = ChildAccount.with_archived.find(account.id)
      expect { target.unarchive! }.to raise_error(ChildAccount::SlotFull)
    end
  end

  describe "slot accounting" do
    it "frees the sandbox limit (archived doesn't count toward sandbox_communicator_count)" do
      user.setup_pro_limits
      user.save!
      create(:child_account, user: user, owner: user, status: "sandbox")
      archived = create(:child_account, user: user, owner: user, status: "sandbox")
      archived.update!(archived_at: Time.current)

      view = user.api_view
      expect(view[:sandbox_communicator_count]).to eq(1)
    end

    it "frees the paid slot when an active is archived (issue #237)" do
      user.setup_pro_limits
      user.save!
      create(:child_account, user: user, owner: user, status: "active")
      archived = create(:child_account, user: user, owner: user, status: "active")
      archived.archive!

      expect(user.paid_communicator_accounts.reload.count).to eq(1)
      expect(user.api_view[:active_communicator_count]).to eq(1)
    end
  end

  describe "team visibility" do
    it "hides an archived active from team_accounts joins" do
      account = create(:child_account, user: user, owner: user, status: "active")
      team = account.ensure_team!(creator: user)
      expect(team.accounts.reload).to include(account)

      account.archive!
      expect(team.accounts.reload).not_to include(account)
    end
  end
end
