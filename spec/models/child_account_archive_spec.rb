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

    it "refuses on a loaner" do
      account = create(:child_account, user: user, owner: user, status: "loaner")
      expect { account.archive! }.to raise_error(ArgumentError)
    end

    it "refuses on an active" do
      account = create(:child_account, user: user, owner: user, status: "active")
      expect { account.archive! }.to raise_error(ArgumentError)
    end
  end

  describe "#unarchive!" do
    it "clears archived_at" do
      account = create(:child_account, user: user, owner: user, status: "sandbox")
      account.archive!
      ChildAccount.with_archived.find(account.id).unarchive!
      expect(account.reload.archived_at).to be_nil
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
  end
end
