# frozen_string_literal: true

require "rails_helper"

# The lifecycle of an ATTACHED board — the shape assignment produces now.
#
# The board on a dashboard is the owner's real board, so detaching must never
# destroy it, and deleting it has to warn about every dashboard it is on. The
# hard-delete-on-detach path survives for LEGACY `is_template` clones only,
# which is what its `is_template` gate guarantees.
RSpec.describe "API::ChildBoards attached-board lifecycle", type: :request do
  let(:owner) { create(:user, plan_type: "pro") }
  let!(:ava) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE,
                           username: "ava-#{SecureRandom.hex(3)}", passcode: "avapw123")
  end
  let!(:ben) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE,
                           username: "ben-#{SecureRandom.hex(3)}", passcode: "benpw123")
  end
  let!(:board) { create(:board, user: owner, name: "Core") }

  before { create(:board_image, board: board, image: create(:image, label: "want")) }

  describe "detaching" do
    it "never destroys an attached board" do
      cb = ava.child_boards.create!(board: board, created_by_id: owner.id)

      expect { delete "/api/child_boards/#{cb.id}", headers: auth_headers(owner) }
        .to change { ChildBoard.where(id: cb.id).count }.from(1).to(0)

      expect(response).to have_http_status(:ok)
      expect(Board.exists?(board.id)).to be true
      expect(owner.boards).to include(board)
    end

    it "leaves the board on the other dashboards it is attached to" do
      cb = ava.child_boards.create!(board: board, created_by_id: owner.id)
      ben.child_boards.create!(board: board, created_by_id: owner.id)

      delete "/api/child_boards/#{cb.id}", headers: auth_headers(owner)

      expect(ben.child_boards.where(board_id: board.id)).to exist
      expect(board.reload.in_use).to be true
    end

    it "clears in_use once the last dashboard detaches" do
      cb = ava.child_boards.create!(board: board, created_by_id: owner.id)
      expect(board.reload.in_use).to be true

      delete "/api/child_boards/#{cb.id}", headers: auth_headers(owner)

      expect(board.reload.in_use).to be false
    end
  end

  describe "deleting a board that is on dashboards" do
    before do
      ava.child_boards.create!(board: board, created_by_id: owner.id)
      ben.child_boards.create!(board: board, created_by_id: owner.id)
    end

    it "answers 409 board_in_use and names every communicator" do
      delete "/api/boards/#{board.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("board_in_use")
      expect(body.dig("usage", "communicators", "count")).to eq(2)
      expect(body.dig("usage", "communicators", "names")).to match_array([ava.name, ben.name])
      expect(Board.exists?(board.id)).to be true
    end

    it "clears both dashboards when confirmed" do
      delete "/api/boards/#{board.id}", params: { confirm: "true" }, headers: auth_headers(owner)

      expect(Board.exists?(board.id)).to be false
      expect(ChildBoard.where(board_id: board.id)).not_to exist
    end
  end
end
