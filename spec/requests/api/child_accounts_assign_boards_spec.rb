require "rails_helper"

# Assignment deep-clone + per-communicator cap. Putting a board on a
# communicator clones the board AND its linked sub-boards (rewired to the
# clones), so the communicator's set is self-contained; the cap bounds how
# many boards a dashboard can hold since assigned clones are uncounted
# toward the owner's board limit.
RSpec.describe "API::ChildAccounts assign_boards", type: :request do
  let(:owner)        { create(:user, plan_type: "pro") }
  let(:communicator) { create(:child_account, user: owner, status: ChildAccount::ACTIVE) }

  def assign!(board_ids)
    post "/api/child_accounts/#{communicator.id}/assign_boards",
         params: { board_ids: board_ids },
         headers: auth_headers(owner)
  end

  describe "deep clone" do
    let!(:source_root) { create(:board, user: owner, name: "Home") }
    let!(:source_sub)  { create(:board, user: owner, name: "Food") }

    before do
      tile = create(:board_image, board: source_root, image: create(:image, label: "Food"))
      tile.update!(predictive_board_id: source_sub.id)
    end

    it "clones the board and its linked sub-boards, rewired to the clones" do
      assign!([source_root.id])
      expect(response).to have_http_status(:ok)

      child_board = communicator.child_boards.find_by(original_board_id: source_root.id)
      expect(child_board).to be_present

      root_clone = child_board.board
      folder = root_clone.board_images.where.not(predictive_board_id: nil).first
      expect(folder.predictive_board_id).not_to eq(source_sub.id)

      sub_clone = Board.find(folder.predictive_board_id)
      expect(sub_clone.user_id).to eq(owner.id)
      expect(sub_clone.is_template).to be true
      expect(sub_clone.settings["assignment_root_id"]).to eq(root_clone.id)
    end

    it "does not change the owner's countable board count" do
      expect { assign!([source_root.id]) }.not_to change { owner.reload.countable_board_count }
    end
  end

  describe "assigned-board cap" do
    let!(:board) { create(:board, user: owner, name: "One More") }

    before { allow(ChildAccount).to receive(:max_assigned_boards).and_return(1) }

    it "returns 422 assigned_board_limit at the cap" do
      create(:child_board, board: create(:board, user: owner), child_account: communicator)

      assign!([board.id])
      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("assigned_board_limit")
      expect(body["limit"]).to eq(1)
      expect(body["count"]).to eq(1)
    end

    it "allows assignment under the cap" do
      assign!([board.id])
      expect(response).to have_http_status(:ok)
      expect(communicator.child_boards.count).to eq(1)
    end
  end
end
