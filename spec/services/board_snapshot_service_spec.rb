# frozen_string_literal: true

require "rails_helper"

# Issue #162 (B6) — snapshot shared boards into family ownership when
# the SLP is removed from a child's team.
RSpec.describe BoardSnapshotService, type: :service do
  let(:slp) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:parent) do
    u = create(:user, created_at: 2.months.ago)
    u.setup_free_limits
    u.save!
    u
  end
  let!(:child) do
    account = create(:child_account, user: parent, owner: parent, status: "active", passcode: "p")
    account.ensure_team!(creator: parent)
    account
  end
  let(:team) { child.primary_team }
  let!(:slp_board) { create(:board, user: slp) }

  before do
    team.upsert_member!(parent, "admin")
    team.upsert_member!(slp, "supervisor")
    team.team_boards.create!(board: slp_board, created_by_id: slp.id)
  end

  it "copies the SLP's shared boards into the family's ownership" do
    result = described_class.snapshot_for_removed_member(team: team, removed_user: slp)

    expect(result.snapshotted_count).to eq(1)

    snapshot = team.boards.where(user_id: parent.id).first
    expect(snapshot).to be_present
    expect(snapshot.name).to eq(slp_board.name)
    expect(snapshot.id).not_to eq(slp_board.id)
  end

  it "doesn't snapshot boards added by other people" do
    other_pro = create(:user)
    other_board = create(:board, user: other_pro)
    team.team_boards.create!(board: other_board, created_by_id: other_pro.id)

    described_class.snapshot_for_removed_member(team: team, removed_user: slp)

    family_boards = team.boards.where(user_id: parent.id)
    expect(family_boards.count).to eq(1)
    expect(family_boards.first.name).to eq(slp_board.name)
  end

  it "is idempotent — running twice does not create duplicate snapshots" do
    described_class.snapshot_for_removed_member(team: team, removed_user: slp)
    result = described_class.snapshot_for_removed_member(team: team, removed_user: slp)
    expect(result.snapshotted_count).to eq(0)
    expect(team.boards.where(user_id: parent.id).count).to eq(1)
  end

  it "leaves the SLP's originals untouched" do
    described_class.snapshot_for_removed_member(team: team, removed_user: slp)
    expect(slp_board.reload.user_id).to eq(slp.id)
  end

  describe "via TeamUser destruction" do
    it "fires on team_user.destroy and the family keeps a copy" do
      slp_team_user = team.team_users.find_by(user_id: slp.id)
      expect { slp_team_user.destroy! }.to change { team.boards.where(user_id: parent.id).count }.from(0).to(1)
    end
  end
end
