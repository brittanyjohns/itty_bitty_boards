require "rails_helper"

# POST /api/boards/:id/clone is the SHALLOW clone: one board, one board slot.
# Folder tiles it can't keep working are flattened into speaking tiles rather
# than left pointing into the source owner's account, and the response says how
# many so the client can tell the user.
RSpec.describe "API::Boards clone", type: :request do
  let(:owner)  { create(:user) }
  let(:cloner) { create(:user) }

  describe "POST /api/boards/:id/clone" do
    it "flattens folder tiles into the source owner's boards and reports the count" do
      source = create(:board, user: owner, name: "Snack Time", published: true)
      target = create(:board, user: owner, name: "Drinks")
      create(:board_image, board: source, predictive_board_id: target.id,
                           data: { "mute_name" => true })

      expect {
        post "/api/boards/#{source.id}/clone", headers: auth_headers(cloner)
      }.to change { Board.count }.by(1) # the root only — no subboard tree

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["flattened_tiles"]).to eq(1)

      clone = Board.find(body["id"])
      expect(clone.user_id).to eq(cloner.id)
      expect(clone.board_images.map(&:predictive_board_id).compact).to be_empty
      expect(clone.board_images.none?(&:door_tile?)).to be(true)
    end

    it "keeps the pointers and reports 0 when the cloner owns the linked boards" do
      cloner.update!(settings: cloner.settings.merge("board_limit" => 10)) # room for the source + link
      target = create(:board, user: cloner, name: "Drinks")
      source = create(:board, user: cloner, name: "Snack Time")
      create(:board_image, board: source, predictive_board_id: target.id,
                           data: { "mute_name" => true })

      post "/api/boards/#{source.id}/clone", params: { name: "Snack Time copy" },
                                             headers: auth_headers(cloner)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["flattened_tiles"]).to eq(0)
      expect(body["name"]).to eq("Snack Time copy")

      clone = Board.find(body["id"])
      expect(clone.board_images.map(&:predictive_board_id)).to eq([target.id])
    end

    it "keeps the api_view_with_images shape alongside the new field" do
      source = create(:board, user: owner, name: "Snack Time", published: true)
      create(:board_image, board: source)

      post "/api/boards/#{source.id}/clone", headers: auth_headers(cloner)

      body = JSON.parse(response.body)
      expect(body).to include("id", "name", "slug", "images", "user_id", "flattened_tiles")
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
  end
end
