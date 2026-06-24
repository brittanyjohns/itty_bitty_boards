require "rails_helper"

# Covers GET /api/board_groups/:id/graph — the bird's-eye map endpoint backed
# by Boards::SetGraphBuilder — plus the deep-link affordance: GET /api/boards/:id
# already returns each tile's BoardImage id for ?focus=<tileId>.
RSpec.describe "API::BoardGroups graph", type: :request do
  let(:user)  { FactoryBot.create(:user) }
  let(:other) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }

  def build_group_for(owner)
    home  = FactoryBot.create(:board, user: owner, name: "Home")
    food  = FactoryBot.create(:board, user: owner, name: "Food")
    FactoryBot.create(:board_image, board: home, image: FactoryBot.create(:image, label: "Food"), predictive_board_id: food.id)
    FactoryBot.create(:board_image, board: food, image: FactoryBot.create(:image, label: "apple"))

    group = FactoryBot.create(:board_group, user: owner, builder: true, layout: {})
    [home, food].each { |b| group.add_board(b) }
    group.update!(root_board_id: home.id)
    { group: group, home: home, food: food }
  end

  describe "authorization" do
    it "rejects anonymous callers with 401" do
      set = build_group_for(user)
      get "/api/board_groups/#{set[:group].id}/graph"
      expect(response).to have_http_status(:unauthorized)
    end

    it "rejects a non-owner non-admin with 403" do
      set = build_group_for(user)
      get "/api/board_groups/#{set[:group].id}/graph", headers: auth_headers(other)
      expect(response).to have_http_status(:forbidden)
    end

    it "allows the owner" do
      set = build_group_for(user)
      get "/api/board_groups/#{set[:group].id}/graph", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end

    it "allows an admin who is not the owner" do
      set = build_group_for(user)
      get "/api/board_groups/#{set[:group].id}/graph", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
    end

    it "404s an unknown set" do
      get "/api/board_groups/0/graph", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "payload" do
    it "returns boards, tiles, edges and stats" do
      set = build_group_for(user)
      get "/api/board_groups/#{set[:group].id}/graph", headers: auth_headers(user)

      body = JSON.parse(response.body)
      expect(body["root_board_id"]).to eq(set[:home].id)
      expect(body["builder"]).to be(true)
      expect(body["stats"]["boards"]).to eq(2)
      expect(body["stats"]["max_depth"]).to eq(1)
      expect(body["edges"]).to include(a_hash_including("from" => set[:home].id, "to" => set[:food].id))

      home = body["boards"].find { |b| b["id"] == set[:home].id }
      folder = home["tiles"].find { |t| t["label"] == "Food" }
      expect(folder["is_folder"]).to be(true)
      expect(folder["links_to_board_id"]).to eq(set[:food].id)
    end
  end

  describe "GET /api/boards/:id tile ids (?focus deep-link support)" do
    it "includes each tile's BoardImage id" do
      home = FactoryBot.create(:board, user: user, name: "Home")
      bi = FactoryBot.create(:board_image, board: home, image: FactoryBot.create(:image, label: "I"))

      get "/api/boards/#{home.id}", headers: auth_headers(user)

      body = JSON.parse(response.body)
      tile = body["images"].find { |t| t["id"] == bi.id }
      expect(tile).to be_present
    end
  end
end
