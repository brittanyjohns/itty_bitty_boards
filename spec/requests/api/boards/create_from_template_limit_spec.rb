require "rails_helper"

# create_from_template was an ungated board-creation path. It now shares the
# board-limit gate (check_board_create_permissions) with create/clone.
RSpec.describe "API::Boards create_from_template board-limit gate", type: :request do
  describe "POST /api/boards/create_from_template" do
    it "returns 422 and builds nothing when the user is already at their limit" do
      user = create(:user) # Free, board_limit 1
      create(:board, user: user) # at limit

      expect {
        post "/api/boards/create_from_template",
             params: { data: "{}" },
             headers: auth_headers(user)
      }.not_to change { Board.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/Maximum number of boards/)
    end

    it "passes the gate and builds when under the limit" do
      user = create(:user) # 0 boards → under limit
      allow(Board).to receive(:create_from_obf) { create(:board, user: user) }

      post "/api/boards/create_from_template",
           params: { data: "{}" },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(Board).to have_received(:create_from_obf)
    end
  end
end
