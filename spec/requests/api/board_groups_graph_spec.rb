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
    # A category tile pins its authored display_label, the way the OBF importer
    # and Boards::BoardTreeBuilder do for a real folder; the word tile below is
    # left to default, which lowercases it.
    FactoryBot.create(:board_image, board: home, display_label: "Food",
                                    image: FactoryBot.create(:image, label: "Food"), predictive_board_id: food.id)
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

    it "is also reachable via the /api/v1/ back-compat alias" do
      set = build_group_for(user)
      get "/api/v1/board_groups/#{set[:group].id}/graph", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["root_board_id"]).to eq(set[:home].id)
      expect(body["stats"]["boards"]).to eq(2)
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

  # The set page labels its button "View map" or "Create map" from `has_map`,
  # so the flag has to agree with the edges the graph actually draws. Every
  # predefined set on production is a flat bag of boards with zero edges.
  describe "has_map" do
    def flag_for(group)
      get "/api/board_groups/#{group.id}", headers: auth_headers(user)
      JSON.parse(response.body)["has_map"]
    end

    def edge_count_for(group)
      get "/api/board_groups/#{group.id}/graph", headers: auth_headers(user)
      JSON.parse(response.body)["edges"].length
    end

    it "is true for a linked set, and agrees with the graph" do
      set = build_group_for(user)

      expect(flag_for(set[:group])).to be(true)
      expect(edge_count_for(set[:group])).to be > 0
    end

    it "is false for a flat set of unlinked boards, and agrees with the graph" do
      group = FactoryBot.create(:board_group, user: user, layout: {})
      2.times do |i|
        board = FactoryBot.create(:board, user: user, name: "Flat #{i}")
        FactoryBot.create(:board_image, board: board,
                                        image: FactoryBot.create(:image, label: "word#{i}"))
        group.add_board(board)
      end

      expect(flag_for(group)).to be(false)
      expect(edge_count_for(group)).to eq(0)
    end

    it "is false when a board links OUT of the set" do
      group = FactoryBot.create(:board_group, user: user, layout: {})
      inside = FactoryBot.create(:board, user: user, name: "Inside")
      outside = FactoryBot.create(:board, user: user, name: "Outside")
      FactoryBot.create(:board_image, board: inside,
                                      image: FactoryBot.create(:image, label: "out"),
                                      predictive_board_id: outside.id)
      group.add_board(inside)

      expect(flag_for(group)).to be(false)
      expect(edge_count_for(group)).to eq(0)
    end

    it "is false for a set with no boards and no root" do
      group = FactoryBot.create(:board_group, user: user, layout: {})

      expect(flag_for(group)).to be(false)
    end
  end

  describe "can_edit on the graph payload" do
    it "is true for the owner" do
      set = build_group_for(user)
      get "/api/board_groups/#{set[:group].id}/graph", headers: auth_headers(user)

      expect(JSON.parse(response.body)["can_edit"]).to be(true)
    end

    it "is false for an anonymous visitor on a curated set" do
      set = build_group_for(admin)
      set[:group].update!(predefined: true)

      get "/api/board_groups/#{set[:group].id}/graph"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["can_edit"]).to be(false)
    end

    it "is true for an admin on someone else's set" do
      set = build_group_for(user)
      get "/api/board_groups/#{set[:group].id}/graph", headers: auth_headers(admin)

      expect(JSON.parse(response.body)["can_edit"]).to be(true)
    end
  end

end
