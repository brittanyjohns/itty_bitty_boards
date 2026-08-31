require "rails_helper"

# POST /api/boards/:id/clone copies the board AND the pages its folder tiles
# open — one board slot per board. When the set is bigger than the user's
# remaining slots it copies what fits, breadth-first, and flattens only the
# tiles whose targets were left behind.
RSpec.describe "API::Boards clone", type: :request do
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

  describe "POST /api/boards/:id/clone" do
    it "copies the whole linked set and rewires the folder tiles to the copies" do
      with_limit(cloner, 10)
      source = create(:board, user: owner, name: "Snack Time", published: true)
      target = create(:board, user: owner, name: "Drinks")
      link!(source, target, label: "Drinks")

      expect {
        post "/api/boards/#{source.id}/clone", headers: auth_headers(cloner)
      }.to change { Board.count }.by(2)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["boards_created"]).to eq(2)
      expect(body["boards_in_set"]).to eq(2)
      expect(body["flattened_tiles"]).to eq(0)
      expect(body["limited_by"]).to be_nil

      clone = Board.find(body["id"])
      pointer = clone.board_images.map(&:predictive_board_id).compact.first
      # Rewired to the COPY, never left aiming into the source owner's account.
      expect(pointer).not_to eq(target.id)
      sub_clone = Board.find(pointer)
      expect(sub_clone.user_id).to eq(cloner.id)
      expect(cloner.boards).to include(sub_clone)
    end

    it "copies what fits and flattens the rest when the set is over the limit" do
      with_limit(cloner, 1)
      source = create(:board, user: owner, name: "Snack Time", published: true)
      target = create(:board, user: owner, name: "Drinks")
      link!(source, target, label: "Drinks")

      expect {
        post "/api/boards/#{source.id}/clone", headers: auth_headers(cloner)
      }.to change { Board.count }.by(1)

      body = JSON.parse(response.body)
      expect(body["boards_created"]).to eq(1)
      expect(body["boards_in_set"]).to eq(2)
      expect(body["flattened_tiles"]).to eq(1)
      expect(body["limited_by"]).to eq("board_limit")

      clone = Board.find(body["id"])
      expect(clone.board_images.map(&:predictive_board_id).compact).to be_empty
      # Flattened, not merely unpointed — a muted tile with no target is a
      # silent button.
      expect(clone.board_images.none?(&:door_tile?)).to be(true)
    end

    it "copies one board and flattens nothing when there are no folder tiles" do
      source = create(:board, user: owner, name: "Snack Time", published: true)
      create(:board_image, board: source)

      post "/api/boards/#{source.id}/clone", params: { name: "Snack Time copy" },
                                             headers: auth_headers(cloner)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["name"]).to eq("Snack Time copy")
      expect(body["boards_created"]).to eq(1)
      expect(body["boards_in_set"]).to eq(1)
      expect(body["flattened_tiles"]).to eq(0)
    end

    it "keeps the api_view_with_images shape alongside the new fields" do
      source = create(:board, user: owner, name: "Snack Time", published: true)
      create(:board_image, board: source)

      post "/api/boards/#{source.id}/clone", headers: auth_headers(cloner)

      body = JSON.parse(response.body)
      expect(body).to include("id", "name", "slug", "images", "user_id",
                              "flattened_tiles", "boards_created", "boards_in_set")
      expect(body["images"].size).to eq(1)
    end

    # The board cap is unchanged by any of the above — a Free user at their
    # limit still gets the 422 upgrade message and no board.
    it "still returns 422 at the board limit" do
      source = create(:board, user: owner, published: true)
      create(:board, user: cloner) # Free, board_limit 1 → at limit

      expect {
        post "/api/boards/#{source.id}/clone", headers: auth_headers(cloner)
      }.not_to change { Board.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/Maximum number of boards/)
    end

    it "404s on an unknown board instead of failing further in" do
      expect {
        post "/api/boards/0/clone", headers: auth_headers(cloner)
      }.not_to change { Board.count }

      expect(response).to have_http_status(:not_found)
    end
  end
end
