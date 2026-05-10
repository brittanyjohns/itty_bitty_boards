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
end
