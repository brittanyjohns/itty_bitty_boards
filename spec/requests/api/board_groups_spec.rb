require "rails_helper"

# Covers the user-facing CRUD opened up in the board-sets-user-crud work:
# owner-or-admin authorization on every mutating action, per-plan creation
# limits, the predefined/featured flag guard, and the new add_board route.
RSpec.describe "API::BoardGroups", type: :request do
  let(:user)  { FactoryBot.create(:user) }        # free, owns nothing yet
  let(:other) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }

  # layout: {} — the shared factory defaults layout to the JSON string "{}",
  # which trips print_grid_layout when a set has no boards; a real jsonb hash
  # is what production rows hold.
  let(:own_group)        { FactoryBot.create(:board_group, user: user, layout: {}) }
  let(:other_group)      { FactoryBot.create(:board_group, user: other, layout: {}) }
  let(:predefined_group) { FactoryBot.create(:board_group, user: admin, predefined: true, layout: {}) }

  describe "POST /api/board_groups (create)" do
    it "rejects anonymous callers with 401" do
      post "/api/board_groups", params: { board_group: { name: "Mine" } }
      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a set for a user under their plan limit (201)" do
      expect {
        post "/api/board_groups", params: { board_group: { name: "Mine" } }, headers: auth_headers(user)
      }.to change { user.board_groups.count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "returns 422 with limit/count when a free user is at their limit" do
      FactoryBot.create(:board_group, user: user) # free limit is 1

      post "/api/board_groups", params: { board_group: { name: "Second" } }, headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_entity)
      body = JSON.parse(response.body)
      expect(body["error"]).to match(/board set limit/i)
      expect(body["limit"]).to eq(1)
      expect(body["count"]).to eq(1)
    end

    it "lets an admin create without a limit" do
      3.times { FactoryBot.create(:board_group, user: admin) }

      post "/api/board_groups", params: { board_group: { name: "Admin set" } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
    end

    it "ignores predefined/featured from a non-admin" do
      post "/api/board_groups",
        params: { board_group: { name: "Sneaky", predefined: true, featured: true } },
        headers: auth_headers(user)

      expect(response).to have_http_status(:created)
      created = user.board_groups.order(:created_at).last
      expect(created.predefined).to be_falsey
      expect(created.featured).to be_falsey
    end

    it "honors predefined/featured from an admin" do
      post "/api/board_groups",
        params: { board_group: { name: "Curated", predefined: true, featured: true } },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:created)
      created = admin.board_groups.order(:created_at).last
      expect(created.predefined).to be true
      expect(created.featured).to be true
    end
  end

  describe "PATCH /api/board_groups/:id (update)" do
    it "rejects anonymous callers with 401" do
      patch "/api/board_groups/#{own_group.id}", params: { board_group: { name: "X" } }
      expect(response).to have_http_status(:unauthorized)
    end

    it "lets the owner update their own set (200)" do
      patch "/api/board_groups/#{own_group.id}",
        params: { board_group: { name: "Renamed", display_image_url: "http://example.com/a.png" } },
        headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(own_group.reload.name).to eq("Renamed")
    end

    it "forbids updating another user's set (403)" do
      patch "/api/board_groups/#{other_group.id}",
        params: { board_group: { name: "Hijack" } }, headers: auth_headers(user)

      expect(response).to have_http_status(:forbidden)
      expect(other_group.reload.name).not_to eq("Hijack")
    end

    it "forbids a non-admin from updating a predefined set (403)" do
      patch "/api/board_groups/#{predefined_group.id}",
        params: { board_group: { name: "Hijack" } }, headers: auth_headers(user)

      expect(response).to have_http_status(:forbidden)
    end

    it "lets an admin update another user's set (200)" do
      patch "/api/board_groups/#{other_group.id}",
        params: { board_group: { name: "Admin edit", display_image_url: "http://example.com/a.png" } },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(other_group.reload.name).to eq("Admin edit")
    end

    it "lets an admin update a predefined set (200)" do
      patch "/api/board_groups/#{predefined_group.id}",
        params: { board_group: { name: "Admin curated", predefined: true, display_image_url: "http://example.com/a.png" } },
        headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(predefined_group.reload.name).to eq("Admin curated")
    end
  end

  describe "DELETE /api/board_groups/:id (destroy)" do
    it "rejects anonymous callers with 401" do
      delete "/api/board_groups/#{own_group.id}"
      expect(response).to have_http_status(:unauthorized)
    end

    it "lets the owner destroy their own set (200)" do
      own_group # create it
      expect {
        delete "/api/board_groups/#{own_group.id}", headers: auth_headers(user)
      }.to change { BoardGroup.where(id: own_group.id).count }.from(1).to(0)
      expect(response).to have_http_status(:ok)
    end

    it "forbids destroying another user's set (403)" do
      other_group
      expect {
        delete "/api/board_groups/#{other_group.id}", headers: auth_headers(user)
      }.not_to change { BoardGroup.where(id: other_group.id).count }
      expect(response).to have_http_status(:forbidden)
    end

    it "lets an admin destroy any set (200)" do
      other_group
      delete "/api/board_groups/#{other_group.id}", headers: auth_headers(admin)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "layout / membership mutations" do
    describe "POST /api/board_groups/:id/save_layout" do
      it "rejects anonymous callers with 401" do
        post "/api/board_groups/#{own_group.id}/save_layout"
        expect(response).to have_http_status(:unauthorized)
      end

      it "lets the owner save layout (200)" do
        post "/api/board_groups/#{own_group.id}/save_layout", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "forbids saving layout on another user's set (403)" do
        post "/api/board_groups/#{other_group.id}/save_layout", headers: auth_headers(user)
        expect(response).to have_http_status(:forbidden)
      end
    end

    describe "POST /api/board_groups/:id/rearrange_boards" do
      it "lets the owner rearrange (200)" do
        post "/api/board_groups/#{own_group.id}/rearrange_boards", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "forbids rearranging another user's set (403)" do
        post "/api/board_groups/#{other_group.id}/rearrange_boards", headers: auth_headers(user)
        expect(response).to have_http_status(:forbidden)
      end
    end

    describe "POST /api/board_groups/:id/remove_board/:board_id" do
      it "lets the owner remove a board from their own set (200)" do
        board = FactoryBot.create(:board, user: user)
        own_group.add_board(board)

        post "/api/board_groups/#{own_group.id}/remove_board/#{board.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(own_group.reload.boards).not_to include(board)
      end

      it "forbids removing a board from another user's set (403)" do
        board = FactoryBot.create(:board, user: other)
        other_group.add_board(board)

        post "/api/board_groups/#{other_group.id}/remove_board/#{board.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:forbidden)
        expect(other_group.reload.boards).to include(board)
      end
    end

    describe "POST /api/board_groups/:id/add_board/:board_id" do
      it "rejects anonymous callers with 401" do
        board = FactoryBot.create(:board, user: user)
        post "/api/board_groups/#{own_group.id}/add_board/#{board.id}"
        expect(response).to have_http_status(:unauthorized)
      end

      it "lets the owner add their own board to their own set (200)" do
        board = FactoryBot.create(:board, user: user)

        post "/api/board_groups/#{own_group.id}/add_board/#{board.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:ok)
        expect(own_group.reload.boards).to include(board)
      end

      it "forbids adding a board to another user's set (403)" do
        board = FactoryBot.create(:board, user: user)

        post "/api/board_groups/#{other_group.id}/add_board/#{board.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:forbidden)
        expect(other_group.reload.boards).not_to include(board)
      end

      it "forbids adding a board the user doesn't own (403)" do
        board = FactoryBot.create(:board, user: other)

        post "/api/board_groups/#{own_group.id}/add_board/#{board.id}", headers: auth_headers(user)

        expect(response).to have_http_status(:forbidden)
        expect(own_group.reload.boards).not_to include(board)
      end
    end
  end
end
