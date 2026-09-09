# frozen_string_literal: true

require "rails_helper"

# Issue #226 — `ChildAccount#ensure_team!` adds the creator as an
# admin team_user automatically. Callers used to have to follow up
# with an explicit `add_member!` call; this guarantees the team is
# never left without an admin row backing the team-creator semantic.
RSpec.describe ChildAccount, "#ensure_team!", type: :model do
  let(:creator) { create(:user, created_at: 2.months.ago) }
  let(:account) { create(:child_account, user: creator, owner: creator) }

  context "when no team exists yet" do
    it "creates a team and pins the creator as admin" do
      team = account.ensure_team!(creator: creator)

      expect(team).to be_persisted
      expect(team.created_by_id).to eq(creator.id)
      tu = team.team_users.find_by(user_id: creator.id)
      expect(tu).to be_present
      expect(tu.role).to eq("admin")
    end

    it "uses the default '<communicator>'s Team' name when no override is given" do
      team = account.ensure_team!(creator: creator)
      expect(team.name).to end_with("'s Team")
    end

    it "uses the override name when one is provided" do
      team = account.ensure_team!(creator: creator, name: "My Custom Team")
      expect(team.name).to eq("My Custom Team")
    end
  end

  context "when a team already exists" do
    it "is idempotent — returns the existing team without touching team_users" do
      first = account.ensure_team!(creator: creator)
      tu_count_before = first.team_users.count

      second = account.ensure_team!(creator: creator)

      expect(second).to eq(first)
      expect(first.team_users.count).to eq(tu_count_before)
    end
  end

  # Issue #887 — a namesake team created for a communicator that already has
  # boards on its dashboard started with `boards == []`, so every invited
  # helper joined a team with nothing shared to work on.
  context "when the communicator already has dashboard boards" do
    let(:board) { create(:board, user: creator) }

    before { ChildBoard.create!(child_account: account, board: board, created_by_id: creator.id) }

    it "seeds the new team with the communicator's dashboard boards" do
      team = account.ensure_team!(creator: creator)

      expect(team.boards).to include(board)
      expect(team.team_boards.find_by(board_id: board.id).created_by_id).to eq(creator.id)
    end

    it "does not retroactively share boards attached after the team existed" do
      team = account.ensure_team!(creator: creator)
      later = create(:board, user: creator)
      ChildBoard.create!(child_account: account, board: later, created_by_id: creator.id)

      account.ensure_team!(creator: creator)

      expect(team.reload.boards).not_to include(later)
    end
  end
end
