require "rails_helper"

# Warn+confirm delete flow: DELETE /api/boards/:id returns 409 board_in_use
# with a usage summary when anything still references the board (folder tiles
# on other boards, communicator dashboards, team shares, or a builder set
# root), unless the client re-sends with confirm=true. Unreferenced boards
# delete in one step, unchanged.
RSpec.describe "API::Boards destroy safety", type: :request do
  let(:user)  { create(:user) }
  let(:board) { create(:board, user: user, name: "Deletable") }

  def delete_board(target, as:, confirm: nil, delete_subboards: nil)
    params = {}
    params[:confirm] = confirm unless confirm.nil?
    params[:delete_subboards] = delete_subboards unless delete_subboards.nil?
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

  describe "a board with subboards of its own" do
    let!(:child)      { create(:board, user: user, name: "Food") }
    let!(:grandchild) { create(:board, user: user, name: "Snacks") }

    before do
      create(:board_image, board: board, predictive_board_id: child.id)
      create(:board_image, board: child, predictive_board_id: grandchild.id)
    end

    it "returns 409 with a subboard summary even when nothing else references it" do
      delete_board(board, as: user)
      expect(response).to have_http_status(:conflict)
      usage = JSON.parse(response.body)["usage"]
      expect(usage["subboards"]).to include(
        "total" => 2, "deletable_count" => 2, "kept_count" => 0,
      )
      expect(usage["subboards"]["names"]).to match_array(["Food", "Snacks"])
      expect(Board.exists?(board.id)).to be true
    end

    it "confirm=true alone deletes only the parent, leaving the subboards" do
      delete_board(board, as: user, confirm: "true")
      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(board.id)).to be false
      expect(Board.exists?(child.id)).to be true
      expect(Board.exists?(grandchild.id)).to be true
    end

    it "delete_subboards=true cascades the whole tree" do
      delete_board(board, as: user, confirm: "true", delete_subboards: "true")
      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(board.id)).to be false
      expect(Board.exists?(child.id)).to be false
      expect(Board.exists?(grandchild.id)).to be false
    end

    it "keeps a subboard something outside the tree still uses" do
      create(:child_board, board: grandchild, child_account: create(:child_account, user: user))

      delete_board(board, as: user, confirm: "true", delete_subboards: "true")
      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(board.id)).to be false
      expect(Board.exists?(child.id)).to be false
      expect(Board.exists?(grandchild.id)).to be true
    end
  end

  # A child page in an imported set carries a Go back tile to the set root,
  # stored as a plain folder tile. Following it made the page look like it owned
  # the whole set, and the cascade offered to delete the set's home board.
  describe "a page in an imported set with a go-back tile to the root" do
    let!(:medic)  { create(:board, user: user, name: "With a Medic") }
    let!(:hurts)  { create(:board, user: user, name: "Where it hurts") }
    let!(:spell)  { create(:board, user: user, name: "Spell a word") }
    let!(:qwerty) { create(:board, user: user, name: "QWERTY Keyboard") }

    before do
      create(:board_image, board: medic, predictive_board_id: hurts.id)
      create(:board_image, board: hurts, predictive_board_id: medic.id)
      create(:board_image, board: spell, predictive_board_id: medic.id)
      create(:board_image, board: spell, predictive_board_id: qwerty.id)

      group = create(:board_group, user: user)
      [medic, hurts, spell].each { |b| group.board_group_boards.create!(board: b) }
      group.update!(root_board_id: medic.id)
    end

    it "does not offer the set root as a subboard of the page" do
      delete_board(spell, as: user)

      expect(response).to have_http_status(:conflict)
      usage = JSON.parse(response.body)["usage"]
      expect(usage["subboards"]["names"]).to eq(["QWERTY Keyboard"])
      expect(usage["subboards"]).to include("total" => 1, "deletable_count" => 1)
    end

    it "cascades only the page's own subboard, leaving the set intact" do
      delete_board(spell, as: user, confirm: "true", delete_subboards: "true")

      expect(response.status).to be_in([200, 204])
      expect(Board.exists?(spell.id)).to be false
      expect(Board.exists?(qwerty.id)).to be false
      expect(Board.exists?(medic.id)).to be true
      expect(Board.exists?(hurts.id)).to be true
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
