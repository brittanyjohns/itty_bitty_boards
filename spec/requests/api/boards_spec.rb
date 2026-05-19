require "rails_helper"

RSpec.describe "API::Boards", type: :request do
  let!(:user)        { create(:user) }
  let!(:other_user)  { create(:user) }
  let!(:board)       { create(:board, user: user, name: "User Board Alpha") }
  let!(:other_board) { create(:board, user: other_user, name: "Other Board Beta") }

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
      expect(new_image.docs.first.current).to be(true)
      expect(board.reload.images).to include(new_image)
    end

    it "demotes existing current docs and makes the uploaded one current on a found-by-label image" do
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
    end
  end
end
