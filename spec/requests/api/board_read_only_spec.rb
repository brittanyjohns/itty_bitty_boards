require "rails_helper"

# A downgraded (free) user over their board limit: the boards beyond their
# limit are read-only. They can still be viewed (usage never breaks), but
# content-mutating endpoints return HTTP 403 board_locked.
RSpec.describe "API board read-only gating", type: :request do
  let(:user) { create(:free_user) } # board_limit 1, past trial window
  let!(:editable_board) { create(:board, user: user, name: "Editable") }
  let!(:locked_board)   { create(:board, user: user, name: "Locked") }

  before { user.update!(editable_board_id: editable_board.id) }

  describe "PATCH /api/boards/:id" do
    it "returns 403 board_locked when editing a locked board" do
      patch "/api/boards/#{locked_board.id}",
            params: { board: { name: "Nope" } },
            headers: auth_headers(user)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("board_locked")
    end

    it "allows editing the designated board" do
      patch "/api/boards/#{editable_board.id}",
            params: { board: { name: "Renamed" } },
            headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
    end
  end

  describe "GET /api/boards/:id on a locked board" do
    it "still serves the board so it stays usable" do
      get "/api/boards/#{locked_board.id}", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["can_edit"]).to be false
    end
  end

  describe "PATCH /api/boards/:id/make_editable" do
    it "moves the editable slot, locking the previous board" do
      patch "/api/boards/#{locked_board.id}/make_editable", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(user.reload.editable_board_id).to eq(locked_board.id)

      patch "/api/boards/#{editable_board.id}",
            params: { board: { name: "Now locked" } },
            headers: auth_headers(user)
      expect(response).to have_http_status(:forbidden)
    end

    it "rejects designating a board the user does not own" do
      others_board = create(:board, user: create(:user))
      patch "/api/boards/#{others_board.id}/make_editable", headers: auth_headers(user)
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
