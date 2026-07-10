require "rails_helper"

# Warn+confirm delete flow: DELETE /api/boards/:id returns 409 board_in_use
# with a usage summary when anything still references the board (folder tiles
# on other boards, communicator dashboards, team shares, or a builder set
# root), unless the client re-sends with confirm=true. Unreferenced boards
# delete in one step, unchanged.
RSpec.describe "API::Boards destroy safety", type: :request do
  let(:user)  { create(:user) }
  let(:board) { create(:board, user: user, name: "Deletable") }

  def delete_board(target, as:, confirm: nil)
    params = confirm.nil? ? {} : { confirm: confirm }
    delete "/api/boards/#{target.id}", params: params, headers: auth_headers(as)
  end

  describe "a board nothing references" do
    it "deletes in one step without confirm" do
      delete_board(board, as: user)
      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(board.id)).to be false
    end
  end

  describe "a board referenced by a folder tile on another board" do
    let!(:referencing_board) { create(:board, user: user, name: "Home Grid") }
    let!(:folder_tile) do
      create(:board_image, board: referencing_board, predictive_board_id: board.id)
    end

    it "returns 409 board_in_use with the referencing board in the usage payload" do
      delete_board(board, as: user)
      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("board_in_use")
      expect(body["board"]).to include("id" => board.id, "name" => "Deletable")
      expect(body["usage"]["referencing_boards"]["count"]).to eq(1)
      expect(body["usage"]["referencing_boards"]["names"]).to include("Home Grid")
      expect(Board.exists?(board.id)).to be true
    end

    it "deletes with confirm=true and nullifies the referencing folder tile" do
      delete_board(board, as: user, confirm: "true")
      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(board.id)).to be false
      expect(folder_tile.reload.predictive_board_id).to be_nil
    end

    it "is not blocked by the board's own self-referencing tile" do
      folder_tile.destroy!
      create(:board_image, board: board, predictive_board_id: board.id)
      delete_board(board, as: user)
      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(board.id)).to be false
    end
  end

  describe "a board on a communicator dashboard" do
    let(:communicator) { create(:child_account, user: user, name: "Milo") }
    let!(:child_board) { create(:child_board, board: board, child_account: communicator) }

    it "returns 409 with the communicator named" do
      delete_board(board, as: user)
      expect(response).to have_http_status(:conflict)
      usage = JSON.parse(response.body)["usage"]
      expect(usage["communicators"]).to eq({ "count" => 1, "names" => ["Milo"] })
    end

    it "deletes with confirm=true, removing the dashboard entry" do
      delete_board(board, as: user, confirm: "true")
      expect(response.status).to be_in([200, 204])
      expect(ChildBoard.exists?(child_board.id)).to be false
    end
  end

  describe "a board shared with a team" do
    let(:team) { create(:team, name: "Room 4", created_by: user) }

    before { TeamBoard.create!(team: team, board: board) }

    it "returns 409 with the team named" do
      delete_board(board, as: user)
      expect(response).to have_http_status(:conflict)
      usage = JSON.parse(response.body)["usage"]
      expect(usage["teams"]).to eq({ "count" => 1, "names" => ["Room 4"] })
    end
  end

  describe "a Board Builder root" do
    let(:communicator) { create(:child_account, user: user) }
    let!(:root) do
      create(:board, user: user, name: "Built Set",
                     settings: { "builder_root" => true })
    end
    let!(:child_page) do
      create(:board, user: user, name: "Food",
                     settings: { "builder_child" => true })
    end
    let!(:group) do
      group = create(:board_group, user: user, builder: true, name: "Built Set")
      group.board_group_boards.create!(board: root)
      group.board_group_boards.create!(board: child_page)
      group.update!(root_board_id: root.id)
      group
    end
    let!(:child_board) { create(:child_board, board: root, child_account: communicator) }

    it "returns 409 describing the whole set" do
      delete_board(root, as: user)
      expect(response).to have_http_status(:conflict)
      usage = JSON.parse(response.body)["usage"]
      expect(usage["builder_set"]).to include(
        "root" => true,
        "board_group_id" => group.id,
        "member_board_count" => 2,
      )
    end

    it "confirm=true cascades the whole set: group, members, and dashboard entry" do
      delete_board(root, as: user, confirm: "true")
      expect(response.status).to be_in([200, 204])
      expect(BoardGroup.exists?(group.id)).to be false
      expect(Board.exists?(root.id)).to be false
      expect(Board.exists?(child_page.id)).to be false
      expect(ChildBoard.exists?(child_board.id)).to be false
    end

    it "a root whose builder group is gone falls back to a plain destroy" do
      group.board_group_boards.destroy_all
      group.delete
      delete_board(root, as: user, confirm: "true")
      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(root.id)).to be false
      # legacy orphan behavior, documented: the child page survives
      expect(Board.exists?(child_page.id)).to be true
    end
  end

  describe "authorization" do
    let(:admin)      { create(:admin_user) }
    let(:other_user) { create(:user) }

    it "lets an admin confirm-delete another user's in-use board" do
      referencing = create(:board, user: user)
      create(:board_image, board: referencing, predictive_board_id: board.id)
      delete_board(board, as: admin, confirm: "true")
      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(board.id)).to be false
    end

    it "still refuses another user's board before any usage check" do
      delete_board(board, as: other_user)
      expect(response.status).to be_in([401, 403, 404])
      expect(Board.exists?(board.id)).to be true
    end
  end

  describe "cleanup job" do
    it "enqueues BoardDestroyCleanupJob on destroy" do
      expect {
        delete_board(board, as: user, confirm: "true")
      }.to change(BoardDestroyCleanupJob.jobs, :size).by(1)
      expect(BoardDestroyCleanupJob.jobs.last["args"]).to eq([board.id])
    end
  end
end
