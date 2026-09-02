require "rails_helper"

# Assignment ATTACHES a board to a dashboard — it does not copy it.
#
# It used to deep-clone the board and its linked sub-boards into `is_template`
# copies that were invisible in the owner's board list and could never receive
# an edit made to the source. One board on N dashboards is the fix: editing it
# reaches every communicator using it, and there is no copy left to diverge.
RSpec.describe "API::ChildAccounts assign_boards", type: :request do
  let(:owner)        { create(:user, plan_type: "pro") }
  let(:communicator) { create(:child_account, user: owner, status: ChildAccount::ACTIVE) }

  def assign!(board_ids)
    post "/api/child_accounts/#{communicator.id}/assign_boards",
         params: { board_ids: board_ids },
         headers: auth_headers(owner)
  end

  describe "attaching a board the owner owns" do
    let!(:source_root) { create(:board, user: owner, name: "Home") }
    let!(:source_sub)  { create(:board, user: owner, name: "Food") }

    before do
      tile = create(:board_image, board: source_root, image: create(:image, label: "Food"))
      tile.update!(predictive_board_id: source_sub.id)
    end

    it "attaches the board itself — no copy, no sub-board copies" do
      expect { assign!([source_root.id]) }.not_to change { Board.count }
      expect(response).to have_http_status(:ok)

      child_board = communicator.child_boards.find_by(board_id: source_root.id)
      expect(child_board).to be_present
      # board IS source, so there is nothing to record as the original.
      expect(child_board.original_board_id).to be_nil
      expect(child_board.created_by_id).to eq(owner.id)
    end

    it "leaves the folder tile pointing at the owner's real sub-board" do
      assign!([source_root.id])

      folder = source_root.reload.board_images.where.not(predictive_board_id: nil).first
      expect(folder.predictive_board_id).to eq(source_sub.id)
    end

    # The whole point of the redesign: one board, so an edit lands everywhere.
    it "serves an edit made after assignment to the communicator" do
      assign!([source_root.id])
      create(:board_image, board: source_root, image: create(:image, label: "more"))

      attached = communicator.child_boards.find_by(board_id: source_root.id).board
      expect(attached.board_images.map(&:label)).to include("more")
    end

    it "does not change the owner's countable board count" do
      expect { assign!([source_root.id]) }.not_to change { owner.reload.countable_board_count }
    end

    # A Free user has exactly one board slot, already spent on their one board.
    # Assignment must never be the thing that asks for a second.
    it "works for a user who is already at their board limit" do
      allow_any_instance_of(User).to receive(:at_board_limit?).and_return(true)

      assign!([source_root.id])
      expect(response).to have_http_status(:ok)
      expect(communicator.child_boards.where(board_id: source_root.id)).to exist
    end

    it "is idempotent — re-assigning the same board does not add a second row" do
      assign!([source_root.id])
      expect { assign!([source_root.id]) }.not_to change { communicator.child_boards.count }
      expect(response).to have_http_status(:ok)
    end

    it "marks the board in use, and names the communicator using it" do
      assign!([source_root.id])

      expect(source_root.reload.in_use).to be true
      expect(source_root.in_use_by).to include(communicator.name)
    end
  end

  describe "boards the caller may not assign" do
    let!(:stranger)       { create(:user) }
    let!(:private_board)  { create(:board, user: stranger, name: "Someone else's") }

    it "refuses a board owned by another user and creates nothing" do
      expect { assign!([private_board.id]) }.not_to change { ChildBoard.count }

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("boards_not_assignable")
      # Generic on purpose — naming the id would say whether it exists.
      expect(body["message"]).not_to include(private_board.id.to_s)
    end

    it "refuses a legacy invisible template clone" do
      legacy = create(:board, user: owner, name: "Legacy", is_template: true)

      expect { assign!([legacy.id]) }.not_to change { ChildBoard.count }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "attaches the assignable ids and reports the rest when a batch is mixed" do
      mine = create(:board, user: owner, name: "Mine")

      assign!([mine.id, private_board.id])
      expect(response).to have_http_status(:ok)
      expect(communicator.child_boards.pluck(:board_id)).to eq([mine.id])
      expect(JSON.parse(response.body)["boards_not_assignable"]).to eq([private_board.id])
    end
  end

  describe "boards the caller does not own but may share" do
    it "attaches a public library board read-only, with no copy" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      public_board = create(:board, user: admin, name: "Core Words",
                                    predefined: true, published: true)

      expect { assign!([public_board.id]) }.not_to change { Board.count }
      expect(response).to have_http_status(:ok)

      child_board = communicator.child_boards.find_by(board_id: public_board.id)
      expect(child_board).to be_present
      expect(public_board.can_edit_for(owner)).to be false
    end

    it "attaches a board shared with the communicator's team" do
      slp = create(:user)
      team = communicator.ensure_team!(creator: owner)
      team.upsert_member!(slp, "supervisor")
      shared = create(:board, user: slp, name: "SLP set")
      team.add_board!(shared, slp.id)

      expect { assign!([shared.id]) }.not_to change { Board.count }
      expect(response).to have_http_status(:ok)
      expect(communicator.child_boards.where(board_id: shared.id)).to exist
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

    # Re-assigning an attached board changes nothing, so charging it against
    # the cap would refuse a request that was already satisfied.
    it "does not count an already-attached board against the cap" do
      create(:child_board, board: board, child_account: communicator)

      assign!([board.id])
      expect(response).to have_http_status(:ok)
    end
  end
end
