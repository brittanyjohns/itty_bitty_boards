require "rails_helper"

RSpec.describe "API::V1::BoardBuilder", type: :request do
  let(:user) { create(:user) }
  let(:communicator) { create(:child_account, user: user) }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  # The "home" template resolves every core label -> Image. Core labels now
  # create-if-missing, so seeding isn't required for a build to succeed; these
  # specs seed to exercise the reuse path and keep label assertions stable.
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

  # Seeds a tiny admin-owned robust set (a "Core 60" root linked to a "Food"
  # fringe page) and stamps the root marker so Boards::RobustSets finds it.
  # Mirrors what `bin/rails vocab_sets:seed` produces, without the OBZ import.
  def seed_robust_set!(slug: "core-60")
    admin = create(:admin_user)
    root  = create(:board, user: admin, name: "Core 60", predefined: true, published: true)
    food  = create(:board, user: admin, name: "Food", predefined: true, published: true)
    create(:board_image, board: root, label: "I", image: create(:image, label: "I", user_id: admin.id))
    food_tile = create(:board_image, board: root, label: "Food",
                                     image: create(:image, label: "Food", user_id: admin.id))
    food_tile.update!(predictive_board_id: food.id)
    create(:board_image, board: food, label: "apple", image: create(:image, label: "apple", user_id: admin.id))
    Boards::RobustSets.mark_root!(root, slug)
    root
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
      expect(home["kind"]).to eq("starter")
    end

    it "includes seeded robust sets, tagged kind=robust" do
      seed_robust_set!
      get "/api/v1/board_builder/templates", headers: headers

      body = JSON.parse(response.body)
      robust = body["templates"].find { |t| t["key"] == "core-60" }
      expect(robust).to be_present
      expect(robust["kind"]).to eq("robust")
      expect(robust["name"]).to eq("Core 60")
      expect(robust["tiles"]).to include("I", "Food")
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

    context "with no core symbols seeded (the staging 500 regression)" do
      # Reproduces the outage: a build used to 500 with
      # RuntimeError("no Image for label \"Food\"") when the curated symbols
      # weren't seeded. Core labels now self-heal, so the build succeeds.
      it "builds successfully, creating images for the core labels" do
        no_seed_user = create(:user)
        no_seed_comm = create(:child_account, user: no_seed_user)
        no_seed_headers = auth_headers(no_seed_user).merge("Content-Type" => "application/json")

        post "/api/v1/board_builder",
             params: { communicator_id: no_seed_comm.id, template: "home" }.to_json,
             headers: no_seed_headers

        expect(response).to have_http_status(:created)
        expect(Image.find_by(label: "Food", user_id: no_seed_user.id)).to be_present
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

    context "board-limit gate (a built tree counts as ONE board)" do
      it "returns 422 and builds nothing when the user is already at their limit" do
        create(:board, user: user) # user is Free (limit 1) → now at limit

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "home" }.to_json,
               headers: headers
        }.not_to change { Board.count }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to match(/Maximum number of boards/)
      end

      it "counts the whole built tree as one, so a second build is blocked" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home",
                       interests: ["dinosaurs"] }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)

        fresh = User.find(user.id)
        # The tree persisted multiple boards, but it counts as one.
        expect(fresh.boards.where(predefined: false).count).to be > 1
        expect(fresh.countable_board_count).to eq(1)

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "keeps the whole built set editable (no spurious board_locked)" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home",
                       interests: ["dinosaurs"] }.to_json,
             headers: headers
        root = Board.find(JSON.parse(response.body)["id"])

        fresh = User.find(user.id)
        child = fresh.boards.where("COALESCE((settings->>'builder_child')::boolean, false)").first
        expect(child).to be_present
        expect(fresh.board_editable?(root)).to be(true)
        expect(fresh.board_editable?(child)).to be(true)
      end
    end

    context "re-run guard (issue #269)" do
      # Raise the board limit so the #270 limit gate doesn't pre-empt the re-run
      # guard — that gate only blocks Free users; the dup problem is paid users.
      before { user.update!(settings: user.settings.to_h.merge("board_limit" => 10)) }

      it "warns with 409 board_builder_set_exists on a re-run and builds nothing" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)
        first_root_id = JSON.parse(response.body)["id"]

        boards_before = Board.count
        child_boards_before = communicator.child_boards.count

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers

        expect(response).to have_http_status(:conflict)
        body = JSON.parse(response.body)
        expect(body["error"]).to eq("board_builder_set_exists")
        expect(body["existing_root_id"]).to eq(first_root_id)

        # Guarded — nothing new was persisted.
        expect(Board.count).to eq(boards_before)
        expect(communicator.child_boards.count).to eq(child_boards_before)
      end

      it "builds another set when confirm=true" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "home", confirm: true }.to_json,
               headers: headers
        }.to change { communicator.child_boards.count }.by(1)

        expect(response).to have_http_status(:created)
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

    context "robust seeded set (clone path)" do
      it "clones the seeded set, favorites the root, and routes interests into the cloned fringe" do
        seed_robust_set!

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "core-60",
                         interests: ["pizza"] }.to_json,
               headers: headers
        }.to change { communicator.child_boards.count }.by(1)

        expect(response).to have_http_status(:created)
        root = Board.find(JSON.parse(response.body)["id"])
        expect(root.name).to eq("Core 60")
        expect(root.user_id).to eq(user.id)
        expect(root.settings["builder_root"]).to be(true)

        child_board = communicator.child_boards.find_by(board_id: root.id)
        expect(child_board.favorite).to eq(true)

        # The whole cloned set counts as ONE board.
        expect(User.find(user.id).countable_board_count).to eq(1)

        # "pizza" routed into the cloned Food fringe page.
        cloned_food = user.boards.find_by(name: "Food")
        expect(cloned_food.board_images.map(&:label)).to include("apple", "pizza")

        expect(communicator.reload.details["interests"]).to eq(["pizza"])
      end

      it "is blocked by the board limit (422) — a cloned set still counts as one" do
        seed_robust_set!
        create(:board, user: user) # Free (limit 1) → at limit

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "core-60" }.to_json,
               headers: headers
        }.not_to change { communicator.child_boards.count }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to match(/Maximum number of boards/)
      end

      it "warns with 409 on a re-run unless confirm=true" do
        seed_robust_set!
        user.update!(settings: user.settings.to_h.merge("board_limit" => 10))

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "core-60" }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "core-60" }.to_json,
             headers: headers
        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)["error"]).to eq("board_builder_set_exists")

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "core-60", confirm: true }.to_json,
               headers: headers
        }.to change { communicator.child_boards.count }.by(1)
        expect(response).to have_http_status(:created)
      end
    end
  end
end
