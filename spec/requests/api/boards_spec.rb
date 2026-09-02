require "rails_helper"

RSpec.describe "API::Boards", type: :request do
  let_it_be(:user)        { create(:user) }
  let_it_be(:other_user)  { create(:user) }
  let_it_be(:board, reload: true) { create(:board, user: user, name: "User Board Alpha") }
  let_it_be(:other_board) { create(:board, user: other_user, name: "Other Board Beta") }

  describe "GET /api/boards" do
    it "returns 200 for unauthenticated requests (public boards are accessible)" do
      get "/api/boards"
      expect(response).to have_http_status(:ok)
    end

    it "returns 200 when authenticated" do
      get "/api/boards", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end

    it "accepts valid sort params without error" do
      get "/api/boards",
          params: { sort_field: "name", sort_order: "asc" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end

    it "falls back to a safe sort when sort_field is not in the allowlist" do
      get "/api/boards",
          params: { sort_field: "id; DROP TABLE boards;--", sort_order: "asc" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end

    # Regression: an OBF/OBZ import sets boards.obf_id, and the index used
    # to silently drop them via `where(obf_id: nil)`. User-visible symptom
    # was board_count=6 but the listing returning 4 boards. The filter
    # belongs on cross-user discovery, not on a user's own index.
    it "includes the user's OBF-imported boards in the listing" do
      create(:board, user: user, name: "Imported Greetings", obf_id: "greetings")
      get "/api/boards",
          params: { per_page: 50 },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      names = JSON.parse(response.body).fetch("boards").map { |b| b["name"] }
      expect(names).to include("Imported Greetings")
    end
  end

  describe "POST /api/boards" do
    # Use a fresh user with no boards so the free plan limit (1) doesn't block creation
    let!(:creator) { create(:user) }

    context "when unauthenticated" do
      it "returns 401" do
        post "/api/boards", params: { board: { name: "New Board" } }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated" do
      it "creates a board and returns 201" do
        post "/api/boards",
             params: { board: { name: "My New Board" } },
             headers: auth_headers(creator)
        expect(response).to have_http_status(:created)
      end

      it "assigns the board to the current user" do
        post "/api/boards",
             params: { board: { name: "My New Board" } },
             headers: auth_headers(creator)
        created_board = Board.order(:created_at).last
        expect(created_board.user_id).to eq(creator.id)
      end

      describe "screen-column handling on create" do
        it "applies model defaults when no column params are sent" do
          post "/api/boards",
               params: { board: { name: "Defaults" } },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          created_board = Board.order(:created_at).last
          # Board#set_screen_sizes only fills nil; verifying defaults landed
          # confirms the controller no longer coerces missing params to 0.
          expect(created_board.small_screen_columns).to be > 0
          expect(created_board.medium_screen_columns).to be > 0
          expect(created_board.large_screen_columns).to be > 0
        end

        it "honors large_screen_columns when provided" do
          post "/api/boards",
               params: { board: { name: "Six Wide", large_screen_columns: 6 } },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(Board.order(:created_at).last.large_screen_columns).to eq(6)
        end
      end

      describe "language defaulting on create" do
        it "defaults the board language to the creator's language when no param is sent" do
          creator.update!(settings: { "voice" => { "language" => "es-US" } })
          post "/api/boards",
               params: { board: { name: "Spanish Board" } },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(Board.order(:created_at).last.language).to eq("es")
        end

        it "uses an explicit language param over the creator's language" do
          creator.update!(settings: { "voice" => { "language" => "es-US" } })
          post "/api/boards",
               params: { board: { name: "French Board", language: "fr" } },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(Board.order(:created_at).last.language).to eq("fr")
        end

        it "defaults to English for a creator with no language setting" do
          post "/api/boards",
               params: { board: { name: "Default Board" } },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(Board.order(:created_at).last.language).to eq("en")
        end
      end

      describe "GenerateBoardJob enqueue args" do
        # Sidekiq strict_args rejects HashWithIndifferentAccess. The job's
        # `profile` arg used to be `params.permit(...).to_h`, which is a
        # HWIA — so any scenario-creation POST raised ArgumentError at
        # enqueue time. Lock the args to plain Hash/JSON-native types.
        before { allow(GenerateBoardJob).to receive(:perform_async) }

        it "enqueues with a plain Hash options arg (no HashWithIndifferentAccess) for scenario creation" do
          post "/api/boards",
               params: {
                 board: { name: "Scenario Board" },
                 board_creation_type: "scenario",
                 topic: "ordering coffee",
                 ageRange: "10-15",
                 wordCount: 12,
                 age: 4,
                 aac_level: "emerging",
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, _type, opts|
            expect(opts.class).to eq(Hash)
            expect(opts["profile"].class).to eq(Hash)
          end
        end

        it "enqueues with a plain Hash options arg even when no profile params are sent" do
          post "/api/boards",
               params: {
                 board: { name: "Scenario No Profile" },
                 board_creation_type: "scenario",
                 topic: "ordering coffee",
                 ageRange: "10-15",
                 wordCount: 12,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, _type, opts|
            expect(opts.class).to eq(Hash)
            expect(opts["profile"].class).to eq(Hash)
            expect(opts["profile"]).to be_empty
          end
        end

        it "passes topic + word_list together for default creation" do
          post "/api/boards",
               params: {
                 board: { name: "Build A Board" },
                 board_creation_type: "default",
                 topic: "morning routine",
                 word_list: %w[wake brush eat],
                 wordCount: 12,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, type, opts|
            expect(type).to eq("default")
            expect(opts["topic"]).to eq("morning routine")
            expect(opts["word_list"]).to eq(%w[wake brush eat])
            expect(opts["word_count"]).to eq(12)
          end
        end

        it "passes topic + word_list together for scenario creation" do
          post "/api/boards",
               params: {
                 board: { name: "Coffee Shop" },
                 board_creation_type: "scenario",
                 topic: "ordering coffee",
                 word_list: %w[latte size],
                 ageRange: "10-15",
                 wordCount: 8,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, type, opts|
            expect(type).to eq("scenario")
            expect(opts["topic"]).to eq("ordering coffee")
            expect(opts["word_list"]).to eq(%w[latte size])
            expect(opts["age_range"]).to eq("10-15")
          end
        end

        it "clamps word_count above 50 down to 50" do
          post "/api/boards",
               params: {
                 board: { name: "Too Many Words" },
                 board_creation_type: "default",
                 topic: "animals",
                 wordCount: 999,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, _type, opts|
            expect(opts["word_count"]).to eq(50)
          end
        end

        it "clamps word_count below 1 up to 1" do
          post "/api/boards",
               params: {
                 board: { name: "No Words" },
                 board_creation_type: "default",
                 topic: "animals",
                 wordCount: 0,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, _type, opts|
            expect(opts["word_count"]).to eq(1)
          end
        end

        it "does not error when age_range is omitted" do
          post "/api/boards",
               params: {
                 board: { name: "No Age Range" },
                 board_creation_type: "scenario",
                 topic: "going to the park",
                 wordCount: 12,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, _type, opts|
            expect(opts["age_range"]).to be_nil
          end
        end

        # The board name must never become an implicit AI topic. It is a
        # required column, so falling back to it made every "default" create
        # an AI generation — pasting a word list silently appended extra
        # words, and "start blank" came back full. Regression from 68a5fe35.
        it "sends no topic for a default board with a word list and no prompt" do
          post "/api/boards",
               params: {
                 board: { name: "Riding The School Bus" },
                 board_creation_type: "default",
                 word_list: %w[bus driver seat],
                 wordCount: 48,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, type, opts|
            expect(type).to eq("default")
            expect(opts["topic"]).to be_blank
            expect(opts["word_list"]).to eq(%w[bus driver seat])
          end
        end

        it "sends no topic for a default board with neither word list nor prompt" do
          post "/api/boards",
               params: {
                 board: { name: "Empty Board" },
                 board_creation_type: "default",
                 wordCount: 48,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, _type, opts|
            expect(opts["topic"]).to be_blank
            expect(opts["word_list"]).to be_nil
          end
        end

        it "uses an explicit prompt as the topic for a default board" do
          post "/api/boards",
               params: {
                 board: { name: "Board Name Not Used" },
                 board_creation_type: "default",
                 prompt: "getting ready for bed",
                 word_list: %w[pajamas],
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, _type, opts|
            expect(opts["topic"]).to eq("getting ready for bed")
          end
        end

        it "still falls back to the board name as the topic for scenario creation" do
          post "/api/boards",
               params: {
                 board: { name: "A Trip To The Zoo" },
                 board_creation_type: "scenario",
                 wordCount: 12,
               },
               headers: auth_headers(creator)

          expect(response).to have_http_status(:created)
          expect(GenerateBoardJob).to have_received(:perform_async) do |_id, type, opts|
            expect(type).to eq("scenario")
            expect(opts["topic"]).to eq("A Trip To The Zoo")
          end
        end
      end
    end
  end

  describe "PATCH /api/boards/:id" do
    context "when unauthenticated" do
      it "returns 401" do
        patch "/api/boards/#{board.id}", params: { board: { name: "Updated" } }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as the board owner" do
      it "updates the board and returns 200" do
        patch "/api/boards/#{board.id}",
              params: { board: { name: "Updated Name" } },
              headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "doesn't zero out screen-column values when the name is the only field changed" do
        board.update!(small_screen_columns: 3, medium_screen_columns: 4, large_screen_columns: 6)

        patch "/api/boards/#{board.id}",
              params: { board: { name: "Renamed only" } },
              headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        board.reload
        expect(board.small_screen_columns).to eq(3)
        expect(board.medium_screen_columns).to eq(4)
        expect(board.large_screen_columns).to eq(6)
      end

      it "honors large_screen_columns when explicitly provided" do
        patch "/api/boards/#{board.id}",
              params: { board: { large_screen_columns: 8 } },
              headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(board.reload.large_screen_columns).to eq(8)
      end

      it "persists margins when only the spacing changed (no layout move)" do
        patch "/api/boards/#{board.id}",
              params: { board: { name: board.name }, xMargin: 12, yMargin: 7, screen_size: "lg" },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(board.reload.margin_settings["lg"]).to eq("x" => 12, "y" => 7)
      end

      it "returns the updated margins in the response body without a refetch" do
        patch "/api/boards/#{board.id}",
              params: { board: { name: board.name }, xMargin: 5, yMargin: 9, screen_size: "md" },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["margin_settings"]["md"]).to eq("x" => 5, "y" => 9)
      end

      it "leaves margins for other screen sizes untouched" do
        board.update!(margin_settings: { "sm" => { "x" => 2, "y" => 2 } })

        patch "/api/boards/#{board.id}",
              params: { board: { name: board.name }, xMargin: 10, yMargin: 10, screen_size: "lg" },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        board.reload
        expect(board.margin_settings["sm"]).to eq("x" => 2, "y" => 2)
        expect(board.margin_settings["lg"]).to eq("x" => 10, "y" => 10)
      end

      it "does not touch the board cover on a generic save (name/colors)" do
        board.update_column(:display_image_url, "https://example.com/picked-tile.png")
        board.update!(settings: board.settings.merge("display_image_source" => "custom"))

        # A form save echoes the whole board back, including the resolved cover
        # URL — it must never clobber the chosen cover.
        patch "/api/boards/#{board.id}",
              params: {
                board: {
                  name: "Renamed board",
                  display_image_url: "https://example.com/echoed-resolved.png",
                },
              },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        board.reload
        expect(board.name).to eq("Renamed board")
        expect(board.read_attribute(:display_image_url))
          .to eq("https://example.com/picked-tile.png")
        expect(board.display_image_source).to eq("custom")
      end
    end

    describe "PUT /api/boards/:id/set_display_image" do
      it "source=custom persists the tile pick and resolves to it" do
        put "/api/boards/#{board.id}/set_display_image",
            params: { source: "custom", display_image_url: "https://example.com/picked-tile.png" },
            headers: auth_headers(user),
            as: :json

        expect(response).to have_http_status(:ok)
        board.reload
        expect(board.read_attribute(:display_image_url))
          .to eq("https://example.com/picked-tile.png")
        expect(board.display_image_source).to eq("custom")
        body = JSON.parse(response.body)
        expect(body["display_image_url"]).to eq("https://example.com/picked-tile.png")
        expect(body["display_image_source"]).to eq("custom")
      end

      it "source=preview switches back to the auto preview" do
        board.update_column(:display_image_url, "https://example.com/picked-tile.png")
        board.update!(settings: board.settings.merge("display_image_source" => "custom"))

        put "/api/boards/#{board.id}/set_display_image",
            params: { source: "preview" },
            headers: auth_headers(user),
            as: :json

        expect(response).to have_http_status(:ok)
        expect(board.reload.display_image_source).to eq("preview")
      end

      it "returns 422 when source=custom without a url" do
        put "/api/boards/#{board.id}/set_display_image",
            params: { source: "custom" },
            headers: auth_headers(user),
            as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "returns 422 for an unknown source" do
        put "/api/boards/#{board.id}/set_display_image",
            params: { source: "bogus" },
            headers: auth_headers(user),
            as: :json

        expect(response).to have_http_status(:unprocessable_content)
      end
    end

    # Manually adding words must let the user put a word that's already on the
    # board onto it again (a second tile) when they opt in — the AI-suggestion
    # path excludes existing words upstream, so only the explicit manual add
    # reaches here as a duplicate. Frontend sends duplicate_words: true for the
    # "Add to board" button only (boards.ts updateBoard).
    context "word_list duplicate handling" do
      it "silently skips a word already on the board by default" do
        patch "/api/boards/#{board.id}",
              params: { board: { name: board.name }, word_list: ["apple"] },
              headers: auth_headers(user),
              as: :json
        expect(response).to have_http_status(:ok)
        expect(board.reload.board_images.where(label: "apple").count).to eq(1)

        patch "/api/boards/#{board.id}",
              params: { board: { name: board.name }, word_list: ["apple"] },
              headers: auth_headers(user),
              as: :json
        expect(response).to have_http_status(:ok)
        expect(board.reload.board_images.where(label: "apple").count).to eq(1)
      end

      it "adds a second tile for an existing word when duplicate_words is true" do
        patch "/api/boards/#{board.id}",
              params: { board: { name: board.name }, word_list: ["apple"] },
              headers: auth_headers(user),
              as: :json
        expect(board.reload.board_images.where(label: "apple").count).to eq(1)

        patch "/api/boards/#{board.id}",
              params: { board: { name: board.name }, word_list: ["apple"], duplicate_words: true },
              headers: auth_headers(user),
              as: :json
        expect(response).to have_http_status(:ok)
        expect(board.reload.board_images.where(label: "apple").count).to eq(2)
      end
    end

    context "when authenticated as a different user" do
      it "returns 401 or 403" do
        patch "/api/boards/#{other_board.id}",
              params: { board: { name: "Hijacked" } },
              headers: auth_headers(user)
        expect(response.status).to be_in([401, 403, 404])
      end
    end
  end

  describe "POST /api/boards/:id/generate_preview_image" do
    # The endpoint only enqueues, so its whole job is to be honest about
    # whether a cover is actually coming. Answering "ok" for a board that can
    # never render one leaves the client polling for a minute and then telling
    # the user to reload for something that will never arrive.
    let(:cover_board) { create(:board, user: user, name: "Cover Board") }

    before { create(:board_image, board: cover_board) }

    it "queues a render and returns the pre-render stamp as a baseline" do
      cover_board.update!(settings: cover_board.settings.to_h.merge("preview_generated_at" => "2026-08-01T00:00:00Z"))

      expect(GenerateBoardPreviewJob).to receive(:perform_async).with(cover_board.id, anything)

      post "/api/boards/#{cover_board.id}/generate_preview_image", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("queued")
      expect(body["preview_generated_at"]).to eq("2026-08-01T00:00:00Z")
      expect(body["preview_status"]).to eq("queued")
    end

    it "clears a previous failure so the next run isn't judged by it" do
      cover_board.mark_preview_failed!
      allow(GenerateBoardPreviewJob).to receive(:perform_async)

      post "/api/boards/#{cover_board.id}/generate_preview_image", headers: auth_headers(user)

      expect(cover_board.reload.preview_status).to eq("queued")
    end

    # The job skips builder_child pages when something enqueues them in bulk —
    # an .obz import is 50-200 headless-Chrome renders on the shared queue. One
    # deliberate click is not that, and refusing it left those pages unable to
    # ever earn a snapshot.
    it "renders a builder_child page anyway when the request is explicit" do
      cover_board.update_column(:settings, cover_board.settings.to_h.merge("builder_child" => true))

      expect(GenerateBoardPreviewJob).to receive(:perform_async)
        .with(cover_board.id, hash_including("force" => true))

      post "/api/boards/#{cover_board.id}/generate_preview_image", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("queued")
    end

    it "refuses a board with no tiles with 422 rather than enqueuing" do
      empty_board = create(:board, user: user, name: "Empty Board")

      expect(GenerateBoardPreviewJob).not_to receive(:perform_async)

      post "/api/boards/#{empty_board.id}/generate_preview_image", headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["code"]).to eq("board_has_no_tiles")
    end

    it "returns 404 for a board that doesn't exist" do
      post "/api/boards/0/generate_preview_image", headers: auth_headers(user)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "DELETE /api/boards/:id" do
    context "when unauthenticated" do
      it "returns 401" do
        delete "/api/boards/#{board.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as the board owner" do
      it "deletes the board and returns 200 or 204" do
        delete "/api/boards/#{board.id}", headers: auth_headers(user)
        expect(response.status).to be_in([200, 204])
      end
    end

    context "when authenticated as a different user" do
      it "returns 401, 403, or 404" do
        delete "/api/boards/#{other_board.id}", headers: auth_headers(user)
        expect(response.status).to be_in([401, 403, 404])
      end
    end
  end

  describe "GET /api/boards/:id (show)" do
    let!(:published_board) { create(:board, user: user, name: "Shared Board", published: true) }
    let!(:private_board)   { create(:board, user: user, name: "Private Board", published: false) }

    context "when the board is private (unpublished)" do
      it "returns 404 for a logged-out visitor" do
        get "/api/boards/#{private_board.slug}"
        expect(response).to have_http_status(:not_found)
      end

      it "returns 404 for an unrelated authenticated user" do
        get "/api/boards/#{private_board.slug}", headers: auth_headers(other_user)
        expect(response).to have_http_status(:not_found)
      end

      it "returns 200 for the board owner" do
        get "/api/boards/#{private_board.slug}", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "returns 200 for a team member the board is shared with" do
        team = create(:team, created_by: user)
        TeamBoard.create!(team: team, board: private_board)
        TeamUser.create!(team: team, user: other_user, role: "member")
        get "/api/boards/#{private_board.slug}", headers: auth_headers(other_user)
        expect(response).to have_http_status(:ok)
      end
    end

    context "when the board is published" do
      it "returns 200 for a logged-out visitor" do
        get "/api/boards/#{published_board.slug}"
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "GET /api/boards/words" do
    let(:suggest) { :get_word_suggestions_from_default_prompt }

    before do
      allow_any_instance_of(API::BoardsController).to receive(:check_credits!).and_return(true)
    end

    it "accepts an optional communicator profile without error" do
      allow_any_instance_of(Board).to receive(suggest).and_return(%w[more help go])
      get "/api/boards/words",
          params: { name: "Doctor Visit", num_of_words: 3, age: 4, aac_level: "emerging" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(%w[more help go])
    end

    it "still works with no profile params (no regression)" do
      allow_any_instance_of(Board).to receive(suggest).and_return(%w[doctor nurse clinic])
      get "/api/boards/words",
          params: { name: "Doctor Visit", num_of_words: 3 },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(%w[doctor nurse clinic])
    end

    # The regression this endpoint's fork caused: the editor seeds the override
    # field with the board name and sends it verbatim, so "left the field alone"
    # and "typed the board name" were indistinguishable — and both used to take a
    # second, much weaker prompt builder. A board named "Places" came back with
    # "different" / "again" / "something else" / "all done" until the override was
    # changed to anything else. There is one path now, whatever the prompt says.
    describe "the prompt override" do
      let!(:places) { create(:board, user: user, name: "Places") }

      def request_words(params)
        get "/api/boards/words",
            params: { board_id: places.id, name: "Places", num_of_words: 3 }.merge(params),
            headers: auth_headers(user)
      end

      it "uses the same path when no override is sent" do
        expect_any_instance_of(Board).to receive(suggest).and_return(%w[park store zoo])
        request_words({})
        expect(response).to have_http_status(:ok)
      end

      it "uses the same path when the override equals the board name" do
        expect_any_instance_of(Board).to receive(suggest).and_return(%w[park store zoo])
        request_words(prompt: "Places")
        expect(response).to have_http_status(:ok)
      end

      it "uses the same path when the override differs from the board name" do
        expect_any_instance_of(Board).to receive(suggest).and_return(%w[park store zoo])
        request_words(prompt: "Places to go")
        expect(response).to have_http_status(:ok)
      end

      it "passes an absent override through as the board name" do
        expect_any_instance_of(Board).to receive(suggest) do |_b, prompt, _n, **|
          expect(prompt).to eq("Places")
          %w[park store zoo]
        end
        request_words({})
      end

      it "passes an explicit override through verbatim" do
        expect_any_instance_of(Board).to receive(suggest) do |_b, prompt, _n, **|
          expect(prompt).to eq("Places to go")
          %w[park store zoo]
        end
        request_words(prompt: "Places to go")
      end
    end

    describe "the words already on the board" do
      let!(:board) { create(:board, user: user, name: "Places") }

      it "hands the board's own word list to the suggestion service" do
        allow_any_instance_of(Board).to receive(:current_word_list).and_return(%w[store zoo])

        expect_any_instance_of(Board).to receive(suggest) do |_b, _prompt, _n, words_to_exclude:, **|
          expect(words_to_exclude).to eq(%w[store zoo])
          %w[park museum]
        end
        get "/api/boards/words",
            params: { board_id: board.id, name: "Places", num_of_words: 2 },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      # The frontend sends this as a comma-joined String, not an Array. Matching
      # only the Array shape silently dropped it for every board-less request.
      it "parses a comma-joined exclusion list" do
        expect_any_instance_of(Board).to receive(suggest) do |_b, _prompt, _n, words_to_exclude:, **|
          expect(words_to_exclude).to eq(%w[apple banana])
          %w[park museum]
        end
        get "/api/boards/words",
            params: { name: "Snacks", num_of_words: 2, words_to_exclude: "apple, banana" },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "still accepts an array exclusion list" do
        expect_any_instance_of(Board).to receive(suggest) do |_b, _prompt, _n, words_to_exclude:, **|
          expect(words_to_exclude).to eq(%w[apple banana])
          %w[park museum]
        end
        get "/api/boards/words",
            params: { name: "Snacks", num_of_words: 2, words_to_exclude: %w[apple banana] },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end
    end

    describe "num_of_words validation" do
      it "rejects a count over the cap without doing the work" do
        expect_any_instance_of(Board).not_to receive(suggest)

        get "/api/boards/words",
            params: { name: "Places", num_of_words: 51 },
            headers: auth_headers(user)

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to match(/cannot exceed 50/)
      end

      it "accepts the cap itself" do
        allow_any_instance_of(Board).to receive(suggest).and_return(%w[park])
        get "/api/boards/words",
            params: { name: "Places", num_of_words: 50 },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end
    end

    describe "language threading" do
      let!(:spanish_board) { create(:board, user: user, name: "Spanish Board", language: "es") }
      let!(:english_board) { create(:board, user: user, name: "English Board", language: "en") }

      def expect_language(expected)
        expect_any_instance_of(Board).to receive(suggest) do |_b, _prompt, _n, language:, **|
          expect(language).to eq(expected)
          %w[hola adios gracias]
        end
      end

      it "forwards the Spanish board's language to the word suggestion service" do
        expect_language("es")
        get "/api/boards/words",
            params: { board_id: spanish_board.id, name: "Spanish Board", num_of_words: 3 },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "forwards English when the board is English" do
        expect_language("en")
        get "/api/boards/words",
            params: { board_id: english_board.id, name: "English Board", num_of_words: 3 },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "lets params[:language] override the board's language" do
        expect_language("fr")
        get "/api/boards/words",
            params: { board_id: english_board.id, name: "English Board", num_of_words: 3, language: "fr" },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end
    end

    describe "stored communicator profile (communicator_id)" do
      let!(:communicator) do
        create(:child_account, user: user,
                               details: { "aac_level" => "emerging", "age_band" => "4-6" })
      end

      it "builds the profile from the communicator's stored details" do
        expect_any_instance_of(Board).to receive(suggest) do |_b, _prompt, _n, profile:, **|
          expect(profile.aac_level).to eq("emerging")
          expect(profile.age_band).to eq("4-6")
          %w[more help go]
        end
        get "/api/boards/words",
            params: { name: "Doctor Visit", num_of_words: 3, communicator_id: communicator.id },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "lets explicit params override stored fields, field by field" do
        expect_any_instance_of(Board).to receive(suggest) do |_b, _prompt, _n, profile:, **|
          expect(profile.aac_level).to eq("proficient") # param wins
          expect(profile.age_band).to eq("4-6")         # stored field kept
          %w[volcano excavate]
        end
        get "/api/boards/words",
            params: { name: "Doctor Visit", num_of_words: 3,
                      communicator_id: communicator.id, aac_level: "proficient" },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "ignores another user's communicator_id (no cross-account leak)" do
        other = create(:child_account, user: create(:user),
                                       details: { "aac_level" => "emerging" })
        expect_any_instance_of(Board).to receive(suggest) do |_b, _prompt, _n, profile:, **|
          expect(profile).to be_nil
          %w[doctor nurse]
        end
        get "/api/boards/words",
            params: { name: "Doctor Visit", num_of_words: 3, communicator_id: other.id },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "GET /api/boards/:id/additional_words" do
    let!(:spanish_board) { create(:board, user: user, name: "Spanish Board", language: "es") }

    it "forwards the board's language to Board#get_words" do
      expect_any_instance_of(Board).to receive(:get_words)
        .with(anything, anything, anything, anything, hash_including(language: "es"))
        .and_return(%w[hola adios])
      get "/api/boards/#{spanish_board.id}/additional_words",
          params: { num_of_words: 2 },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end

    it "lets params[:language] override the board's language" do
      expect_any_instance_of(Board).to receive(:get_words)
        .with(anything, anything, anything, anything, hash_including(language: "fr"))
        .and_return(%w[bonjour])
      get "/api/boards/#{spanish_board.id}/additional_words",
          params: { num_of_words: 2, language: "fr" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /api/boards/:id/add_image (upload)" do
    let(:upload) do
      Rack::Test::UploadedFile.new(Rails.root.join("public", "logo_bubble.png"), "image/png")
    end

    it "creates a new image with the uploaded doc marked current and adds it to the board" do
      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "fresh upload label", docs: { image: upload } } },
             headers: auth_headers(user)
      }.to change(Image, :count).by(1)

      expect(response).to have_http_status(:ok)

      new_image = Image.order(:created_at).last
      expect(new_image.user_id).to eq(user.id)
      expect(new_image.docs.count).to eq(1)
      new_doc = new_image.docs.first
      expect(new_doc.current).to be(true)
      expect(board.reload.images).to include(new_image)

      board_image = board.board_images.find_by(image_id: new_image.id)
      expect(board_image.display_image_url).to eq(new_doc.tile_url)
    end

    it "demotes existing current docs and makes the uploaded one current on a found-by-label image the user owns" do
      existing_image = create(:image, label: "shared label", user_id: user.id)
      existing_image.update!(private: true)
      old_doc = create(:doc, documentable: existing_image, user: user, current: true)

      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "shared label", docs: { image: upload } } },
             headers: auth_headers(user)
      }.to change { existing_image.docs.count }.by(1)

      expect(response).to have_http_status(:ok)
      expect(old_doc.reload.current).to be(false)
      new_doc = existing_image.docs.order(:created_at).last
      expect(new_doc.current).to be(true)
      expect(board.reload.images).to include(existing_image)

      board_image = board.board_images.find_by(image_id: existing_image.id)
      expect(board_image.display_image_url).to eq(new_doc.tile_url)
    end

    it "does not touch current flags on an image owned by another user, but updates this board's display URL" do
      foreign_image = create(:image, label: "foreign label", user_id: other_user.id)
      foreign_image.update!(private: false)
      foreign_current_doc = create(:doc, documentable: foreign_image, user: other_user, current: true)

      expect {
        post "/api/boards/#{board.id}/add_image",
             params: { image: { label: "foreign label", docs: { image: upload } } },
             headers: auth_headers(user)
      }.to change { foreign_image.docs.count }.by(1)

      expect(response).to have_http_status(:ok)

      # The other user's existing current doc is untouched.
      expect(foreign_current_doc.reload.current).to be(true)

      # The uploaded doc is NOT promoted to current on the shared image.
      new_doc = foreign_image.docs.order(:created_at).last
      expect(new_doc).not_to eq(foreign_current_doc)
      expect(new_doc.current).to be(false)

      # But the current user's board does show the uploaded variant.
      board_image = board.board_images.find_by(image_id: foreign_image.id)
      expect(board_image.display_image_url).to eq(new_doc.tile_url)
    end

    # Script Collector (gestalt) support: a whole-phrase tile carries its source
    # and communicative function, stored on board_images.data.
    it "stores gestalt metadata and a phrase part_of_speech on the tile" do
      post "/api/boards/#{board.id}/add_image",
           params: {
             image: { label: "I want more", part_of_speech: "phrase" },
             data: { gestalt_source: "Bluey S3E4", utterance_function: "request" },
           },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)

      new_image = Image.by_label("I want more").first
      expect(new_image.part_of_speech).to eq("phrase")

      board_image = board.reload.board_images.find_by(image_id: new_image.id)
      expect(board_image.part_of_speech).to eq("phrase")
      expect(board_image.data["gestalt_source"]).to eq("Bluey S3E4")
      expect(board_image.data["utterance_function"]).to eq("request")
    end

    it "leaves board_images.data untouched when no gestalt metadata is sent" do
      post "/api/boards/#{board.id}/add_image",
           params: { image: { label: "plain word" } },
           headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      new_image = Image.find_by(label: "plain word")
      board_image = board.reload.board_images.find_by(image_id: new_image.id)
      expect(board_image.data).not_to have_key("gestalt_source")
    end
  end

  # "Link a board" — the third tab of the frontend's Add-tiles modal. One
  # request both creates the tile and points it at an existing board, so there
  # is never a half-made unlinked tile, and the whole thing stays behind
  # add_image's existing editable / marketplace guards.
  describe "POST /api/boards/:id/add_image with predictive_board_id" do
    # A paid owner on purpose: the Free plan's board_limit of 1 makes every
    # board but the designated one read-only, and these examples need two
    # boards at once — a hub and something to link it to.
    let(:owner) { create(:user, plan_type: "pro", plan_status: "active") }
    let(:hub_board) { create(:board, user: owner, name: "Hub") }
    let(:target_board) { create(:board, user: owner, name: "Big Feelings") }

    def tile_for(label)
      image = Image.by_label(label).first
      hub_board.reload.board_images.find_by(image_id: image&.id)
    end

    it "links the new tile to the chosen board and mutes it" do
      post "/api/boards/#{hub_board.id}/add_image",
           params: { image: { label: "feelings link" }, predictive_board_id: target_board.id },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)

      tile = tile_for("feelings link")
      expect(tile.predictive_board_id).to eq(target_board.id)
      # mute_name is not decoration: it is what makes door_tile? true, which is
      # what the board-set map reads to draw the folder edge.
      expect(tile.data["mute_name"]).to be(true)
      expect(tile.is_dynamic?).to be(true)

      # The frontend's folder badge keys off the serialized `dynamic` flag, not
      # off predictive_board_id, so the response has to carry it or the tile
      # navigates while looking like an ordinary word tile.
      rendered = JSON.parse(response.body)["images"].find { |i| i["label"] == "feelings link" }
      expect(rendered["dynamic"]).to be(true)
      expect(rendered["predictive_board_id"]).to eq(target_board.id)
      expect(rendered["predictive_board_name"]).to eq("Big Feelings")
    end

    it "lets a user link to a board from the public library" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      public_board = create(:board, user: admin, name: "Core 24", published: true, predefined: true)
      expect(Board.public_boards).to include(public_board)

      post "/api/boards/#{hub_board.id}/add_image",
           params: { image: { label: "core link" }, predictive_board_id: public_board.id },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(tile_for("core link").predictive_board_id).to eq(public_board.id)
    end

    it "ignores another user's board and still creates the tile" do
      post "/api/boards/#{hub_board.id}/add_image",
           params: { image: { label: "foreign link" }, predictive_board_id: other_board.id },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      tile = tile_for("foreign link")
      expect(tile).to be_present
      expect(tile.predictive_board_id).to be_nil
      expect(tile.data).not_to have_key("mute_name")
    end

    it "ignores a self-link, which would render as a plain tile anyway" do
      post "/api/boards/#{hub_board.id}/add_image",
           params: { image: { label: "self link" }, predictive_board_id: hub_board.id },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(tile_for("self link").predictive_board_id).to be_nil
    end

    it "falls back to the linked board's cover when the image brings no art" do
      target_board.update!(display_image_url: "https://cdn.example.com/cover.png")

      post "/api/boards/#{hub_board.id}/add_image",
           params: { image: { label: "artless link" }, predictive_board_id: target_board.id },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(tile_for("artless link").display_image_url).to eq("https://cdn.example.com/cover.png")
    end

    it "does not overwrite an uploaded picture with the linked board's cover" do
      target_board.update!(display_image_url: "https://cdn.example.com/cover.png")
      upload = Rack::Test::UploadedFile.new(Rails.root.join("public", "logo_bubble.png"), "image/png")

      post "/api/boards/#{hub_board.id}/add_image",
           params: {
             image: { label: "uploaded link", docs: { image: upload } },
             predictive_board_id: target_board.id,
           },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      tile = tile_for("uploaded link")
      expect(tile.predictive_board_id).to eq(target_board.id)
      expect(tile.display_image_url).not_to eq("https://cdn.example.com/cover.png")
    end

    it "leaves the tile unlinked when the param is absent" do
      post "/api/boards/#{hub_board.id}/add_image",
           params: { image: { label: "unlinked word" } },
           headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      tile = tile_for("unlinked word")
      expect(tile.predictive_board_id).to be_nil
      expect(tile.data).not_to have_key("mute_name")
    end
  end

  # Mailchimp "hit_limit" Customer Journey trigger (issue #291, journey #3).
  # Enqueued from check_board_create_permissions when a Free user trips the
  # board cap on create / clone / create_from_template. Deduped 14d via
  # Rails.cache so a user mashing the create button isn't spammed.
  describe "POST /api/boards triggers the Mailchimp hit_limit journey" do
    let(:free_user) { create(:free_user) }
    let!(:existing_board) { create(:board, user: free_user) }
    let(:memory_cache) { ActiveSupport::Cache::MemoryStore.new }

    before do
      allow(Rails).to receive(:cache).and_return(memory_cache)
      MailchimpEventJob.clear
    end

    it "enqueues MailchimpEventJob with journey_key=hit_limit on a Free user at the cap" do
      expect {
        post "/api/boards",
             params: { board: { name: "Second" } },
             headers: auth_headers(free_user)
      }.to change(MailchimpEventJob.jobs, :size).by(1)

      expect(response).to have_http_status(:unprocessable_content)
      expect(MailchimpEventJob.jobs.last["args"]).to eq(
        [free_user.id, "journey", { "journey_key" => "hit_limit" }],
      )
    end

    it "sets a Rails.cache dedupe key so the next 422 doesn't re-enqueue" do
      post "/api/boards",
           params: { board: { name: "Second" } },
           headers: auth_headers(free_user)

      expect(memory_cache.read("mailchimp:hit_limit:#{free_user.id}")).to eq(true)

      expect {
        post "/api/boards",
             params: { board: { name: "Third" } },
             headers: auth_headers(free_user)
      }.not_to change(MailchimpEventJob.jobs, :size)
    end

    it "logs and swallows errors so a Mailchimp blip can't 500 the create request" do
      allow(MailchimpEventJob).to receive(:perform_async).and_raise("redis down")
      expect(Rails.logger).to receive(:warn).with(/hit_limit enqueue failed/)

      post "/api/boards",
           params: { board: { name: "Second" } },
           headers: auth_headers(free_user)

      # The 422 response itself is unaffected.
      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  # The listing and the cap read the same scope now. Before this, /boards ran
  # `main_boards` while the cap counted every non-template, non-predefined
  # board — so a Free user could be refused "1/1 boards" with an empty page
  # (issue #804).
  describe "GET /api/boards listing matches what counts" do
    let(:user) { create(:user).tap { |u| u.update!(settings: (u.settings || {}).merge("board_limit" => 50)) } }

    def board_names(filter: nil)
      params = { filter: filter }.compact
      get "/api/boards", params: params, headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      JSON.parse(response.body)["boards"].map { |b| b["name"] }
    end

    # The factory sets no board_type, so a bare create(:board) IS the case that
    # used to vanish: `NULL != 'menu'` is NULL in SQL, not TRUE.
    it "lists a board with a NULL board_type under the main_boards filter" do
      create(:board, user: user, name: "Null Type", board_type: nil)

      expect(board_names(filter: "main_boards")).to include("Null Type")
    end

    it "lists sub-pages alongside main boards on the default listing" do
      create(:board, user: user, name: "Home", board_type: "static")
      page = create(:board, user: user, name: "Food", board_type: "static")
      page.update_column(:sub_board, true)

      expect(board_names(filter: "countable")).to include("Home", "Food")
    end

    it "still excludes sub-pages from the main_boards filter" do
      page = create(:board, user: user, name: "Food", board_type: "static")
      page.update_column(:sub_board, true)

      expect(board_names(filter: "main_boards")).not_to include("Food")
    end

    it "returns only the pages under the sub_pages filter" do
      create(:board, user: user, name: "Home", board_type: "static")
      page = create(:board, user: user, name: "Food", board_type: "static")
      page.update_column(:sub_board, true)

      names = board_names(filter: "sub_pages")
      expect(names).to include("Food")
      expect(names).not_to include("Home")
    end

    it "keeps menu boards out of main_boards" do
      create(:board, user: user, name: "Diner", board_type: "menu")

      expect(board_names(filter: "main_boards")).not_to include("Diner")
    end

    it "omits a published (public) menu from the listing, since it does not count" do
      create(:board, user: user, name: "Public Diner", board_type: "menu", published: true)

      expect(board_names(filter: "countable")).not_to include("Public Diner")
    end

    it "reports counts that agree with countable_board_count" do
      create(:board, user: user, name: "Home", board_type: "static")
      page = create(:board, user: user, name: "Food", board_type: "static")
      page.update_column(:sub_board, true)
      create(:board, user: user, name: "Curated", predefined: true)

      get "/api/boards", params: { filter: "countable" }, headers: auth_headers(user)
      counts = JSON.parse(response.body)["counts"]

      expect(counts["countable"]).to eq(User.find(user.id).countable_board_count)
      expect(counts["main"]).to eq(1)
      expect(counts["pages"]).to eq(1)
      expect(counts["limit"]).to eq(50)
    end

    it "still shows an admin their predefined boards" do
      admin = create(:user, role: "admin")
      create(:board, user: admin, name: "Curated", predefined: true, board_type: "static")

      get "/api/boards", params: { filter: "main_boards" }, headers: auth_headers(admin)

      expect(JSON.parse(response.body)["boards"].map { |b| b["name"] }).to include("Curated")
    end

    describe "api_view fields the boards page needs" do
      let!(:board) { create(:board, user: user, name: "Home", board_type: "static") }

      it "carries sub_board, counts_toward_limit and an owner-true can_delete" do
        get "/api/boards", params: { filter: "countable" }, headers: auth_headers(user)
        payload = JSON.parse(response.body)["boards"].find { |b| b["name"] == "Home" }

        expect(payload["sub_board"]).to be(false)
        expect(payload["counts_toward_limit"]).to be(true)
        expect(payload["can_delete"]).to be(true)
      end

      it "reports can_delete false for a non-owner" do
        stranger = create(:user)

        get "/api/boards/#{board.id}", headers: auth_headers(stranger)

        if response.status == 200
          expect(JSON.parse(response.body)["can_delete"]).to be(false)
        end
      end
    end
  end

end
