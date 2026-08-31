require "rails_helper"

# GET /api/boards/:id/clone_plan sizes the copy BEFORE anything is created, so
# the client can confirm with real numbers instead of spending slots the user
# never agreed to. It shares the board-limit gate with #clone, so a user with
# no room is refused here rather than after the confirm.
RSpec.describe "API::Boards clone_plan", type: :request do
  let(:owner)  { create(:user) }
  let(:cloner) { create(:user) }

  def with_limit(user, n)
    user.update!(settings: (user.settings || {}).merge("board_limit" => n))
    user
  end

  def link!(from_board, to_board, label:)
    create(:board_image, board: from_board, image: create(:image, label: label),
                         predictive_board_id: to_board.id,
                         data: { "mute_name" => true })
  end

  describe "GET /api/boards/:id/clone_plan" do
    it "reports the whole set when it fits, and creates nothing" do
      with_limit(cloner, 10)
      source = create(:board, user: owner, name: "Snack Time", published: true)
      link!(source, create(:board, user: owner, name: "Drinks"), label: "Drinks")

      expect {
        get "/api/boards/#{source.id}/clone_plan", headers: auth_headers(cloner)
      }.not_to change { Board.count }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include(
        "boards_in_set" => 2,
        "boards_to_create" => 2,
        "tiles_to_flatten" => 0,
        "remaining_slots" => 10,
        "board_limit" => 10,
        "board_count" => 0,
        "limited_by" => nil,
        "truncated" => false,
      )
    end

    it "reports the shortfall when the set is bigger than the remaining slots" do
      with_limit(cloner, 1)
      source = create(:board, user: owner, published: true)
      link!(source, create(:board, user: owner, name: "Drinks"), label: "Drinks")

      get "/api/boards/#{source.id}/clone_plan", headers: auth_headers(cloner)

      body = JSON.parse(response.body)
      expect(body["boards_in_set"]).to eq(2)
      expect(body["boards_to_create"]).to eq(1)
      expect(body["tiles_to_flatten"]).to eq(1)
      expect(body["limited_by"]).to eq("board_limit")
    end

    it "reports a one-board set for a board with no folder tiles" do
      source = create(:board, user: owner, published: true)
      create(:board_image, board: source)

      get "/api/boards/#{source.id}/clone_plan", headers: auth_headers(cloner)

      body = JSON.parse(response.body)
      expect(body["boards_in_set"]).to eq(1)
      expect(body["boards_to_create"]).to eq(1)
      expect(body["limited_by"]).to be_nil
    end

    # Same gate as #clone, so the client meets the upgrade path one request
    # earlier instead of after the user has confirmed.
    it "returns the board-limit 422 when the user has no room at all" do
      source = create(:board, user: owner, published: true)
      create(:board, user: cloner) # Free, board_limit 1 → at limit

      get "/api/boards/#{source.id}/clone_plan", headers: auth_headers(cloner)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error_code"]).to eq("board_limit_reached")
    end

    it "requires a signed-in user" do
      source = create(:board, user: owner, published: true)

      get "/api/boards/#{source.id}/clone_plan"

      expect(response).to have_http_status(:unauthorized)
    end

    it "404s on an unknown board" do
      get "/api/boards/0/clone_plan", headers: auth_headers(cloner)

      expect(response).to have_http_status(:not_found)
    end
  end
end
