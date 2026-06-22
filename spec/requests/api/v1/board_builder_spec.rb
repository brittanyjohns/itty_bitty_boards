require "rails_helper"

RSpec.describe "API::V1::BoardBuilder", type: :request do
  let(:user) { create(:user) }
  let(:communicator) { create(:child_account, user: user) }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  before { allow_any_instance_of(Grover).to receive(:to_png).and_return(ChunkyPNG::Image.new(1, 1).to_blob) }

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

    it "includes complexity levels with key, name, description, fringe_page_range" do
      get "/api/v1/board_builder/templates", headers: headers

      body = JSON.parse(response.body)
      levels = body["levels"]
      expect(levels.size).to eq(3)
      keys = levels.map { |l| l["key"] }
      expect(keys).to eq(%w[starter standard extended])
      levels.each do |level|
        expect(level).to have_key("name")
        expect(level).to have_key("description")
        expect(level).to have_key("fringe_page_range")
      end
    end

    it "includes grid dimensions in levels" do
      get "/api/v1/board_builder/templates", headers: headers
      levels = JSON.parse(response.body)["levels"]
      starter = levels.find { |l| l["key"] == "starter" }
      expect(starter["grid_rows"]).to eq(6)
      expect(starter["grid_columns"]).to eq(10)
      extended = levels.find { |l| l["key"] == "extended" }
      expect(extended["grid_rows"]).to eq(7)
      expect(extended["grid_columns"]).to eq(12)
    end

    describe "recommended_level" do
      it "is null without a communicator_id" do
        get "/api/v1/board_builder/templates", headers: headers
        expect(JSON.parse(response.body)["recommended_level"]).to be_nil
      end

      it "is null when the communicator has no stored profile" do
        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers
        expect(JSON.parse(response.body)["recommended_level"]).to be_nil
      end

      it "recommends starter for a young/emerging communicator" do
        communicator.update!(details: { "aac_level" => "emerging", "age_band" => "4-6" })
        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        body = JSON.parse(response.body)
        expect(body["recommended_level"]).to eq("starter")
        expect(body["recommendation_reason"]).to be_present
      end

      it "recommends standard for a developing communicator (age 11+)" do
        communicator.update!(details: { "aac_level" => "developing", "age_band" => "11-14" })
        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        expect(JSON.parse(response.body)["recommended_level"]).to eq("standard")
      end

      it "recommends standard for a young teen (11-14)" do
        communicator.update!(details: { "age_band" => "11-14" })
        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        expect(JSON.parse(response.body)["recommended_level"]).to eq("standard")
      end

      it "recommends extended for an older proficient communicator" do
        communicator.update!(details: { "aac_level" => "proficient", "age_band" => "15-18" })
        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        expect(JSON.parse(response.body)["recommended_level"]).to eq("extended")
      end
    end

    describe "recommended_template" do
      it "is null without a communicator_id" do
        seed_robust_set!
        get "/api/v1/board_builder/templates", headers: headers

        body = JSON.parse(response.body)
        expect(body["recommended_template"]).to be_nil
        expect(body["recommendation_reason"]).to be_nil
      end

      it "is null when the communicator has no stored profile" do
        seed_robust_set!
        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        expect(JSON.parse(response.body)["recommended_template"]).to be_nil
      end

      it "recommends the small core set for a young/emerging communicator" do
        seed_robust_set!(slug: "core-60")
        communicator.update!(details: { "aac_level" => "emerging", "age_band" => "4-6" })

        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        body = JSON.parse(response.body)
        expect(body["recommended_template"]).to eq("core-60")
        expect(body["recommendation_reason"]).to be_present
      end

      it "recommends the large core set for an older proficient communicator" do
        seed_robust_set!(slug: "core-84")
        communicator.update!(details: { "aac_level" => "proficient", "age_band" => "15-18" })

        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        expect(JSON.parse(response.body)["recommended_template"]).to eq("core-84")
      end

      it "is null when the recommended set isn't seeded in this environment" do
        communicator.update!(details: { "aac_level" => "emerging" })

        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        expect(JSON.parse(response.body)["recommended_template"]).to be_nil
      end

      it "ignores another user's communicator_id" do
        seed_robust_set!
        other = create(:child_account, user: create(:user),
                                       details: { "aac_level" => "emerging" })

        get "/api/v1/board_builder/templates",
            params: { communicator_id: other.id }, headers: headers

        expect(JSON.parse(response.body)["recommended_template"]).to be_nil
      end
    end

    describe "GLP templates (gestalt language support)" do
      def seed_glp_templates!
        Boards::GlpTemplates.seed!(admin: create(:admin_user))
      end

      it "includes seeded GLP templates (kind=glp), with no recommendation absent a communicator" do
        seed_glp_templates!
        get "/api/v1/board_builder/templates", headers: headers

        body = JSON.parse(response.body)
        glp = body["templates"].find { |t| t["key"] == "glp-greetings-social" }
        expect(glp).to be_present
        expect(glp["kind"]).to eq("glp")
        expect(body["glp_templates"].map { |t| t["key"] }).to include("glp-greetings-social")
        # No communicator → no GLP recommendation.
        expect(body["recommended_template"]).to be_nil
      end

      it "recommends a stage-appropriate GLP template when the communicator has a glp_stage" do
        seed_glp_templates!
        communicator.update!(details: { "glp_stage" => 1 })

        get "/api/v1/board_builder/templates",
            params: { communicator_id: communicator.id }, headers: headers

        body = JSON.parse(response.body)
        expect(body["recommended_template"]).to eq("glp-greetings-social")
        expect(body["recommendation_reason"]).to match(/gestalt|NLA Stage 1/i)
      end

      it "returns only GLP templates with ?template_type=glp" do
        seed_glp_templates!
        get "/api/v1/board_builder/templates",
            params: { template_type: "glp" }, headers: headers

        body = JSON.parse(response.body)
        kinds = body["templates"].map { |t| t["kind"] }.uniq
        expect(kinds).to eq(["glp"])
        expect(body["templates"].map { |t| t["key"] }).not_to include("home")
      end
    end
  end

  describe "GET /api/v1/board_builder/interest_categories" do
    it "returns all categories with sorted words and max_interests" do
      get "/api/v1/board_builder/interest_categories", headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body["max_interests"]).to eq(20)
      categories = body["categories"]
      expect(categories.size).to be >= 15

      names = categories.map { |c| c["name"] }
      expect(names).to eq(names.sort)
      expect(names).to include("Food", "Animals", "Music", "Play")

      food = categories.find { |c| c["name"] == "Food" }
      expect(food["words"]).to eq(food["words"].sort)
      expect(food["words"]).to include("pizza", "apple")
    end
  end

  describe "POST /api/v1/board_builder" do
    before do
      seed_template_images!
      BuildBoardSetJob.clear # Sidekiq fake-mode queues accumulate across examples
    end

    context "without auth" do
      it "returns 401" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "happy path (async)" do
      it "returns 201 immediately with the root in building_board and enqueues BuildBoardSetJob with the right args" do
        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "home",
                         interests: ["dinosaurs", "grandma"] }.to_json,
               headers: headers
        }.to change { communicator.child_boards.count }.by(1)
          .and change { BuildBoardSetJob.jobs.size }.by(1)

        expect(response).to have_http_status(:created)
        body = JSON.parse(response.body)
        expect(body["status"]).to eq("building_board")

        root = Board.find(body["id"])
        expect(root.name).to eq("Home")
        expect(root.user_id).to eq(user.id)
        expect(root.settings["builder_root"]).to be(true)
        expect(root.status).to eq("building_board")
        # The root is created bare — the job builds the tiles/sub-boards.
        expect(root.board_images.count).to eq(0)

        # Attach + favorite happen in-request, so the set shows on the
        # communicator immediately (in "building" state).
        child_board = communicator.child_boards.find_by(board_id: root.id)
        expect(child_board.favorite).to eq(true)

        # Interests are normalized + persisted in-request for re-run prefill.
        expect(communicator.reload.details["interests"]).to eq(["dinosaurs", "grandma"])

        expect(BuildBoardSetJob.jobs.last["args"])
          .to eq([root.id, communicator.id, "home", ["dinosaurs", "grandma"], {}])
      end

      it "builds a linked set, routes interests into category vs favorites folders, and completes (job drained)" do
        # dinosaurs -> the template's Play folder; grandma -> "My Favorites".
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home",
                       interests: ["dinosaurs", "grandma"] }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)

        BuildBoardSetJob.drain

        root = Board.find(JSON.parse(response.body)["id"])
        expect(root.status).to eq("complete")

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

        # Only the ROOT carries a generation status; children stay default.
        sub_boards = User.find(user.id).boards
                         .where("COALESCE((settings->>'builder_child')::boolean, false)")
        expect(sub_boards).to be_present
        expect(sub_boards.pluck(:status)).not_to include("building_board", "complete", "failed")
      end

      it "accepts interests as { word, category } hashes and routes by explicit category" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home",
                       interests: [
                         { word: "pizza", category: "Food" },
                         { word: "grandma", category: "Play" },
                       ] }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)

        body = JSON.parse(response.body)
        expect(communicator.reload.details["interests"]).to eq(["pizza", "grandma"])

        BuildBoardSetJob.drain

        root = Board.find(body["id"])
        # "grandma" has no dictionary category but was explicitly routed to Play
        play_tile = root.board_images.find { |bi| bi.label == "Play" }
        play_board = Board.find(play_tile.predictive_board_id)
        expect(play_board.board_images.map(&:label)).to include("grandma")

        # No "My Favorites" needed — everything was explicitly routed
        expect(root.board_images.map(&:label)).not_to include("My Favorites")
      end

      it "accepts more than 12 interests (new max is 20)" do
        interests = (1..15).map { |n| "word#{n}" }
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home",
                       interests: interests }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)

        expect(communicator.reload.details["interests"].size).to eq(15)
      end

      it "builds the core template with no favorites folder when interests are empty" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home", interests: [] }.to_json,
             headers: headers

        expect(response).to have_http_status(:created)
        BuildBoardSetJob.drain

        root = Board.find(JSON.parse(response.body)["id"])
        expect(root.board_images.map(&:label)).not_to include("My Favorites")
      end
    end

    context "with a GLP template" do
      def seed_glp_templates!
        Boards::GlpTemplates.seed!(admin: create(:admin_user))
      end

      it "accepts a GLP template slug (regression: used to 422 unknown_template)" do
        seed_glp_templates!

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id,
                         template: "glp-greetings-social" }.to_json,
               headers: headers
        }.to change { BuildBoardSetJob.jobs.size }.by(1)

        expect(response).to have_http_status(:created)
        root = Board.find(JSON.parse(response.body)["id"])
        # Root takes the GLP template's name, and the slug rides through to the job.
        expect(root.name).to eq("Greetings & Social")
        expect(BuildBoardSetJob.jobs.last["args"][2]).to eq("glp-greetings-social")
      end

      it "builds the whole-phrase tiles onto the root and completes (job drained)" do
        seed_glp_templates!
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id,
                       template: "glp-greetings-social" }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)

        BuildBoardSetJob.drain

        root = Board.find(JSON.parse(response.body)["id"])
        expect(root.status).to eq("complete")
        expect(root.board_images.map(&:label)).to include("hi there!", "see you later")
        expect(root.board_images.map { |bi| bi.image.part_of_speech }.uniq).to eq(["phrase"])
      end

      it "still 422s unknown_template for a bogus glp-looking slug" do
        seed_glp_templates!
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id,
                       template: "glp-does-not-exist" }.to_json,
             headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("unknown_template")
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
        BuildBoardSetJob.drain
        expect(Image.find_by(label: "Food", user_id: no_seed_user.id)).to be_present
        expect(Board.find(JSON.parse(response.body)["id"]).status).to eq("complete")
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
      it "returns 422, builds nothing, and enqueues no job" do
        jobs_before = BuildBoardSetJob.jobs.size
        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "nope" }.to_json,
               headers: headers
        }.not_to change { Board.count }
        expect(BuildBoardSetJob.jobs.size).to eq(jobs_before)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    context "board-limit gate (a built tree counts as ONE board)" do
      it "returns 422, builds nothing, and enqueues no job when the user is already at their limit" do
        create(:board, user: user) # user is Free (limit 1) → now at limit
        jobs_before = BuildBoardSetJob.jobs.size

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "home" }.to_json,
               headers: headers
        }.not_to change { Board.count }
        expect(BuildBoardSetJob.jobs.size).to eq(jobs_before)

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to match(/Maximum number of boards/)
      end

      it "counts the whole built tree as one, so a second build is blocked" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home",
                       interests: ["dinosaurs"] }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)
        BuildBoardSetJob.drain

        fresh = User.find(user.id)
        # The tree persisted multiple boards, but it counts as one.
        expect(fresh.boards.where(predefined: false).count).to be > 1
        expect(fresh.countable_board_count).to eq(1)

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:unprocessable_content)
      end

      it "keeps the whole built set editable (no spurious board_locked)" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home",
                       interests: ["dinosaurs"] }.to_json,
             headers: headers
        BuildBoardSetJob.drain
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
        BuildBoardSetJob.drain

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

      it "trips the guard even while the first build is still running (#271 async window)" do
        # Root exists with status building_board the moment the 201 returns —
        # a concurrent second request must 409, not double-build.
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)
        root_id = JSON.parse(response.body)["id"]
        expect(Board.find(root_id).status).to eq("building_board") # job not drained

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)["error"]).to eq("board_builder_set_exists")
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

    context "when serializing the 201 payload fails after the job is enqueued" do
      it "still returns 201 with a minimal payload and leaves the build running" do
        # Board#api_view can trip on transient ActiveStorage/variant races.
        # By then the root is committed and BuildBoardSetJob is enqueued —
        # a 422 here would be a false failure (and would mark a running
        # build "failed" out from under the job).
        allow_any_instance_of(Board).to receive(:api_view).and_raise(StandardError, "variant race")

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "home" }.to_json,
               headers: headers
        }.to change { BuildBoardSetJob.jobs.size }.by(1)

        expect(response).to have_http_status(:created)
        body = JSON.parse(response.body)
        expect(body["name"]).to eq("Home")
        expect(body["status"]).to eq("building_board")

        root = Board.find(body["id"])
        expect(root.status).to eq("building_board") # not stomped to "failed"
      end
    end

    context "when something fails in-request after the root was created" do
      it "returns 422 build_failed and marks the root failed (no stuck building_board)" do
        allow(BuildBoardSetJob).to receive(:perform_async).and_raise(StandardError, "redis down")

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to eq("build_failed")

        root = communicator.reload.board_builder_root
        expect(root).to be_present
        expect(root.status).to eq("failed")
      end
    end

    context "when the build job fails mid-build" do
      # The full failure matrix (transaction rollback, no orphan children,
      # retry idempotency) lives in spec/sidekiq/build_board_set_job_spec.rb;
      # this covers the user-visible request-level artifact.
      it "leaves the root as the failed artifact and the next run 409s until confirmed" do
        # Lift the Free board limit so the second POST reaches the 409 guard
        # (the limit gate runs first and the failed root still counts as one).
        user.update!(settings: user.settings.to_h.merge("board_limit" => 10))
        allow_any_instance_of(Boards::BoardTreeBuilder)
          .to receive(:call).and_raise(Boards::BoardTreeBuilder::BuildError, "boom")

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:created)
        root_id = JSON.parse(response.body)["id"]

        expect { BuildBoardSetJob.drain }.to raise_error(Boards::BoardTreeBuilder::BuildError)
        expect(Board.find(root_id).status).to eq("failed")

        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, template: "home" }.to_json,
             headers: headers
        expect(response).to have_http_status(:conflict)
        expect(JSON.parse(response.body)["error"]).to eq("board_builder_set_exists")
      end
    end

    context "robust seeded set (clone path)" do
      it "returns 201 with a building_board root named for the set, then the job clones and routes interests" do
        seed_robust_set!

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "core-60",
                         interests: ["pizza"] }.to_json,
               headers: headers
        }.to change { communicator.child_boards.count }.by(1)
          .and change { BuildBoardSetJob.jobs.size }.by(1)

        expect(response).to have_http_status(:created)
        root = Board.find(JSON.parse(response.body)["id"])
        expect(root.name).to eq("Core 60")
        expect(root.user_id).to eq(user.id)
        expect(root.settings["builder_root"]).to be(true)
        expect(root.status).to eq("building_board")

        child_board = communicator.child_boards.find_by(board_id: root.id)
        expect(child_board.favorite).to eq(true)

        expect(communicator.reload.details["interests"]).to eq(["pizza"])
        expect(BuildBoardSetJob.jobs.last["args"])
          .to eq([root.id, communicator.id, "core-60", ["pizza"], {}])

        BuildBoardSetJob.drain
        root.reload
        expect(root.status).to eq("complete")

        # The whole cloned set counts as ONE board.
        expect(User.find(user.id).countable_board_count).to eq(1)

        # Cloned core tiles landed on the SAME root the 201 returned.
        expect(root.board_images.map(&:label)).to include("I", "Food")

        # "pizza" routed into the cloned Food fringe page, linked from the root.
        cloned_food = user.boards.find_by(name: "Food")
        expect(cloned_food.board_images.map(&:label)).to include("apple", "pizza")
        food_tile = root.board_images.find { |bi| bi.label == "Food" }
        expect(food_tile.predictive_board_id).to eq(cloned_food.id)

        # The user's copy must never surface as a pickable robust template.
        expect(Boards::RobustSets.all_roots.pluck(:id)).not_to include(root.id)
      end

      it "is blocked by the board limit (422) — a cloned set still counts as one" do
        seed_robust_set!
        create(:board, user: user) # Free (limit 1) → at limit

        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, template: "core-60" }.to_json,
               headers: headers
        }.not_to change { communicator.child_boards.count }

        expect(response).to have_http_status(:unprocessable_content)
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

    context "complexity level param (Phase 2)" do
      before do
        seed_robust_set!
        seed_template_images!
        BuildBoardSetJob.clear
      end

      it "returns 201 and enqueues the job with the level key" do
        expect {
          post "/api/v1/board_builder",
               params: { communicator_id: communicator.id, level: "standard",
                         interests: ["pizza"] }.to_json,
               headers: headers
        }.to change { BuildBoardSetJob.jobs.size }.by(1)

        expect(response).to have_http_status(:created)
        body = JSON.parse(response.body)
        expect(body["status"]).to eq("building_board")
        expect(body["name"]).to eq("Core 60")

        expect(BuildBoardSetJob.jobs.last["args"][2]).to eq("standard")
      end

      it "returns 422 for an unknown level" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, level: "mega" }.to_json,
             headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
        expect(JSON.parse(response.body)["error"]).to eq("unknown_template")
      end

      it "returns 422 when neither level nor template is provided" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id }.to_json,
             headers: headers

        expect(response).to have_http_status(:unprocessable_entity)
      end

      it "prefers level over template when both are sent" do
        post "/api/v1/board_builder",
             params: { communicator_id: communicator.id, level: "starter",
                       template: "home" }.to_json,
             headers: headers

        expect(response).to have_http_status(:created)
        expect(BuildBoardSetJob.jobs.last["args"][2]).to eq("starter")
      end
    end
  end
end
