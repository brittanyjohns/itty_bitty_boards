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

      it "clears the display_image_url column when settings.display_follows_preview is true" do
        board.update_column(:display_image_url, "https://example.com/old-preview.png")

        patch "/api/boards/#{board.id}",
              params: {
                board: {
                  display_image_url: "https://example.com/old-preview.png",
                  settings: { display_follows_preview: true },
                },
              },
              headers: auth_headers(user),
              as: :json

        expect(response).to have_http_status(:ok)
        board.reload
        expect(board.read_attribute(:display_image_url)).to be_nil
        expect(board.settings["display_follows_preview"]).to be true
      end

      it "keeps the display_image_url column when the flag is not set" do
        patch "/api/boards/#{board.id}",
              params: {
                board: {
                  display_image_url: "https://example.com/user-cover.png",
                },
              },
              headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(board.reload.read_attribute(:display_image_url))
          .to eq("https://example.com/user-cover.png")
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
    before do
      allow_any_instance_of(API::BoardsController).to receive(:check_credits!).and_return(true)
    end

    it "accepts an optional communicator profile without error" do
      allow_any_instance_of(Board).to receive(:get_word_suggestions).and_return(%w[more help go])
      get "/api/boards/words",
          params: { name: "Doctor Visit", num_of_words: 3, age: 4, aac_level: "emerging" },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(%w[more help go])
    end

    it "still works with no profile params (no regression)" do
      allow_any_instance_of(Board).to receive(:get_word_suggestions).and_return(%w[doctor nurse clinic])
      get "/api/boards/words",
          params: { name: "Doctor Visit", num_of_words: 3 },
          headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to eq(%w[doctor nurse clinic])
    end

    describe "language threading" do
      let!(:spanish_board) { create(:board, user: user, name: "Spanish Board", language: "es") }
      let!(:english_board) { create(:board, user: user, name: "English Board", language: "en") }

      it "forwards the Spanish board's language to the word suggestion service" do
        expect_any_instance_of(Board).to receive(:get_word_suggestions)
          .with("Spanish Board", 3, anything, hash_including(language: "es")).and_return(%w[hola adios gracias])
        get "/api/boards/words",
            params: { board_id: spanish_board.id, name: "Spanish Board", num_of_words: 3 },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "forwards English when the board is English" do
        expect_any_instance_of(Board).to receive(:get_word_suggestions)
          .with("English Board", 3, anything, hash_including(language: "en")).and_return(%w[more help go])
        get "/api/boards/words",
            params: { board_id: english_board.id, name: "English Board", num_of_words: 3 },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "lets params[:language] override the board's language" do
        expect_any_instance_of(Board).to receive(:get_word_suggestions)
          .with("English Board", 3, anything, hash_including(language: "fr")).and_return(%w[bonjour merci])
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
        expect_any_instance_of(Board).to receive(:get_word_suggestions) do |_b, _p, _n, _excl, profile:, **|
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
        expect_any_instance_of(Board).to receive(:get_word_suggestions) do |_b, _p, _n, _excl, profile:, **|
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
        expect_any_instance_of(Board).to receive(:get_word_suggestions) do |_b, _p, _n, _excl, profile:, **|
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
end
