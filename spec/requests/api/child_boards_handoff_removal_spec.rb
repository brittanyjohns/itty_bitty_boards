# frozen_string_literal: true

require "rails_helper"

# Non-destructive board removal after a hand-off. Removing a board from the
# communicator dashboard must never destroy a board the team (or another
# communicator) still relies on — see ChildBoardsController#destroy and
# ChildAccount#register_dashboard_boards_on_team!.
RSpec.describe "API::ChildBoards non-destructive removal", type: :request do
  let(:parent) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:slp)    { create(:user, plan_type: "pro", created_at: 2.months.ago) }

  # Post-claim shape: parent owns the active communicator; SLP is a supervisor.
  let!(:child_account) do
    create(:child_account, user: parent, owner: parent,
                           status: ChildAccount::ACTIVE, passcode: "ownerpw1")
  end
  let!(:team) do
    t = child_account.ensure_team!(creator: parent)
    t.upsert_member!(slp, "supervisor")
    t
  end

  it "detaches but preserves a template board that is also a team board" do
    board = create(:board, user: slp, name: "Inherited", is_template: true)
    cb = create(:child_board, board: board, child_account: child_account)
    team.add_board!(board, slp.id) # the transfer safety net

    expect {
      delete "/api/child_boards/#{cb.id}", headers: auth_headers(parent)
    }.to change { ChildBoard.where(id: cb.id).count }.from(1).to(0)

    expect(response).to have_http_status(:ok)
    expect(Board.exists?(board.id)).to be(true)
    # And it's now available to re-add from the team pool.
    expect(child_account.reload.available_teams_boards.map(&:board_id)).to include(board.id)
  end

  it "preserves a template board still on another communicator's dashboard" do
    board = create(:board, user: slp, name: "Shared template", is_template: true)
    cb = create(:child_board, board: board, child_account: child_account)
    other = create(:child_account, user: slp, owner: slp, status: ChildAccount::ACTIVE,
                                   passcode: "x", username: "other-#{SecureRandom.hex(2)}")
    create(:child_board, board: board, child_account: other)

    delete "/api/child_boards/#{cb.id}", headers: auth_headers(parent)

    expect(response).to have_http_status(:ok)
    expect(Board.exists?(board.id)).to be(true)
  end

  it "detaches a non-template board without deleting it" do
    board = create(:board, user: slp, name: "Library board") # is_template defaults false
    cb = create(:child_board, board: board, child_account: child_account)

    delete "/api/child_boards/#{cb.id}", headers: auth_headers(parent)

    expect(response).to have_http_status(:ok)
    expect(Board.exists?(board.id)).to be(true)
  end

  it "detaches but preserves a template board another board's folder tile still opens" do
    board = create(:board, user: parent, name: "Linked sub-board", is_template: true)
    cb = create(:child_board, board: board, child_account: child_account)
    home = create(:board, user: parent, name: "Home")
    create(:board_image, board: home, predictive_board_id: board.id)

    delete "/api/child_boards/#{cb.id}", headers: auth_headers(parent)

    expect(response).to have_http_status(:ok)
    expect(ChildBoard.exists?(cb.id)).to be(false)
    expect(Board.exists?(board.id)).to be(true)
  end

  it "still deletes a throwaway template clone nothing else references (cleanup preserved)" do
    board = create(:board, user: parent, name: "Throwaway", is_template: true)
    cb = create(:child_board, board: board, child_account: child_account)

    expect {
      delete "/api/child_boards/#{cb.id}", headers: auth_headers(parent)
    }.to change { Board.where(id: board.id).count }.from(1).to(0)

    expect(response).to have_http_status(:ok)
  end

  describe "orphan sweep of deep-cloned sub-templates" do
    # Shape Boards::AssignmentCloner leaves behind: a root template on the
    # dashboard whose folder tile opens a sub-template marked with the root id.
    def build_assigned_set!(assigner)
      root = create(:board, user: assigner, name: "Assigned Home", is_template: true)
      sub  = create(:board, user: assigner, name: "Assigned Food", is_template: true,
                            settings: { "assignment_child" => true, "assignment_root_id" => root.id })
      tile = create(:board_image, board: root, image: create(:image, label: "Food"))
      tile.update!(predictive_board_id: sub.id)
      cb = create(:child_board, board: root, child_account: child_account)
      [root, sub, cb]
    end

    it "sweeps the sub-templates when the root template is removed and deleted" do
      root, sub, cb = build_assigned_set!(parent)

      delete "/api/child_boards/#{cb.id}", headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      expect(Board.exists?(root.id)).to be(false)
      expect(Board.exists?(sub.id)).to be(false)
    end

    it "spares a sub-template that another surface still references" do
      root, sub, cb = build_assigned_set!(parent)
      elsewhere = create(:board, user: parent, name: "Elsewhere")
      external_tile = create(:board_image, board: elsewhere, image: create(:image, label: "link"))
      external_tile.update!(predictive_board_id: sub.id)

      delete "/api/child_boards/#{cb.id}", headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      expect(Board.exists?(root.id)).to be(false)
      expect(Board.exists?(sub.id)).to be(true)
    end
  end

  it "exposes can_remove on the dashboard boards for the communicator owner" do
    board = create(:board, user: slp, name: "Inherited", is_template: true)
    create(:child_board, board: board, child_account: child_account)

    view = child_account.api_view(parent)
    entry = view[:boards].find { |b| b[:board_id] == board.id }

    expect(entry[:can_remove]).to be(true)   # owns the communicator
    expect(entry[:can_edit]).to be(false)    # but not the board itself
  end
end
