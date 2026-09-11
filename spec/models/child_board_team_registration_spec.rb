# frozen_string_literal: true

require "rails_helper"

# Issue #914 — `register_dashboard_boards_on_team!` runs only at `ensure_team!`
# and at the claim hand-off, so a board attached AFTER the team already existed
# was never registered on it. That is the ordinary order of operations (create
# the communicator, then give them boards), which left `team.boards == []`
# permanently and the owner's team page reading "SHARED BOARDS 0" beside a
# starred, attached board.
RSpec.describe ChildBoard, "team registration", type: :model do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) { create(:child_account, user: owner, owner: owner) }
  let(:board) { Board.create!(name: "Core Words", user: owner) }

  it "registers a board attached after the team already exists" do
    team = account.ensure_team!(creator: owner)
    expect(team.boards).to be_empty

    account.child_boards.create!(board: board, created_by_id: owner.id)

    expect(team.reload.boards).to include(board)
  end

  it "attributes the team board to the board's owner" do
    team = account.ensure_team!(creator: owner)
    account.child_boards.create!(board: board, created_by_id: owner.id)

    expect(team.team_boards.find_by(board_id: board.id).created_by_id).to eq(owner.id)
  end

  it "is idempotent when the board is already on the team" do
    team = account.ensure_team!(creator: owner)
    team.add_board!(board, owner.id)

    expect {
      account.child_boards.create!(board: board, created_by_id: owner.id)
    }.not_to change { team.reload.team_boards.count }
  end

  it "does nothing when the communicator has no team" do
    expect(account.teams).to be_empty

    expect {
      account.child_boards.create!(board: board, created_by_id: owner.id)
    }.not_to raise_error
  end

  # Sharing a board with the team is a convenience for the people around the
  # communicator; it must never stop a board reaching the child's dashboard.
  it "never fails the attach when the team write raises" do
    team = account.ensure_team!(creator: owner)
    allow_any_instance_of(Team).to receive(:add_board!).and_raise(StandardError, "boom")

    child_board = nil
    expect {
      child_board = account.child_boards.create!(board: board, created_by_id: owner.id)
    }.not_to raise_error

    expect(child_board).to be_persisted
    expect(team.reload.boards).to be_empty
  end
end
