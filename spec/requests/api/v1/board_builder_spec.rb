require "rails_helper"

RSpec.describe "API::V1::BoardBuilder", type: :request do
  let(:user) { create(:user) }
  let(:communicator) { create(:child_account, user: user) }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  # The "home" template resolves every core label -> Image; seed them so a build
  # doesn't blow up on a missing symbol.
  def seed_template_images!
    collect_labels(Boards::StarterBlueprints::HOME).each do |label|
      create(:image, label: label, user_id: user.id)
    end
  end

  def collect_labels(tree)
    Array(tree[:tiles]).flat_map do |tile|
      [tile[:label]] + (tile[:children] ? collect_labels(tile[:children]) : [])
    end
  end

  describe "GET /api/v1/board_builder/templates" do
    it "returns the label-only catalog" do
      get "/api/v1/board_builder/templates", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      keys = body["templates"].map { |t| t["key"] }
      expect(keys).to include("home", "daily_routine")
      home = body["templates"].find { |t| t["key"] == "home" }
      expect(home["tiles"]).to include("I", "Food")
    end
  end

  describe "POST /api/v1/board_builder" do
    before { seed_template_images! }

    context "without auth" do
      it "returns 401" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "happy path" do
      it "builds a linked set, routes interests into category vs favorites folders, and persists interests" do
        # dinosaurs -> the template's Play folder; grandma -> "My Favorites".
        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "home",
                         interests: ["dinosaurs", "grandma"] }.to_json,
               headers: headers
        }.to change { communicator.child_boards.count }.by(1)

        expect(response).to have_http_status(:created)
        body = JSON.parse(response.body)

        root = Board.find(body["id"])
        expect(root.name).to eq("Home")
        expect(root.user_id).to eq(user.id)

        child_board = communicator.child_boards.find_by(board_id: root.id)
        expect(child_board.favorite).to eq(true)

        # "dinosaurs" was routed into the existing Play folder (alongside seeds).
        play_tile = root.board_images.find { |bi| bi.label == "Play" }
        expect(play_tile.predictive_board_id).to be_present
        play_board = Board.find(play_tile.predictive_board_id)
        expect(play_board.board_images.map(&:label)).to include("dinosaurs", "ball")

        # "grandma" had no category folder, so it landed in "My Favorites".
        favorites_tile = root.board_images.find { |bi| bi.label == "My Favorites" }
        expect(favorites_tile.predictive_board_id).to be_present
        favorites_board = Board.find(favorites_tile.predictive_board_id)
        expect(favorites_board.board_images.map(&:label)).to contain_exactly("grandma")

        expect(communicator.reload.details["interests"]).to eq(["dinosaurs", "grandma"])
      end

      it "builds the core template with no favorites folder when interests are empty" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home", interests: [] }.to_json,
             headers: headers

        expect(response).to have_http_status(:created)
        root = Board.find(JSON.parse(response.body)["id"])
        expect(root.board_images.map(&:label)).not_to include("My Favorites")
      end
    end

    context "communicator the user doesn't own" do
      it "returns 404" do
        other = create(:child_account, user: create(:user))
        post "/api/v1/board_builder",
             params: { communicator_id: other.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:not_found)
      end
    end

    context "unknown template" do
      it "returns 422 and builds nothing" do
        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "nope" }.to_json,
               headers: headers
        }.not_to change { Board.count }
        expect(response).to have_http_status(:unprocessable_entity)
      end
    end

    context "when the tree builder fails mid-build" do
      it "returns 422 build_failed with a warm message" do
        allow_any_instance_of(Boards::BoardTreeBuilder)
          .to receive(:call).and_raise(Boards::BoardTreeBuilder::BuildError, "boom")

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("build_failed")
      end
    end
  end
end
