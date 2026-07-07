require "rails_helper"

# Issue #26 (IDOR): board-image mutations must be scoped to the caller's own
# boards. Before this fix, `BoardImage.find(params[:id])` (and the unscoped
# `set_board_image` before_action) loaded any board image, and the existing
# `check_board_image_editable!` gate does NOT enforce ownership — it returns
# true for boards you don't own — so any authenticated user could edit or
# delete another user's tile. These specs prove a non-owner now gets a 404.
RSpec.describe "API::BoardImages IDOR", type: :request do
  let!(:user)       { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:admin)      { create(:admin_user) }

  let!(:board)       { create(:board, user: user) }
  let!(:board_image) { create(:board_image, board: board) }

  let!(:other_board)       { create(:board, user: other_user) }
  let!(:other_board_image) { create(:board_image, board: other_board) }

  describe "a non-owner is rejected with 404 (not the record)" do
    it "PATCH /api/board_images/:id (update)" do
      patch "/api/board_images/#{other_board_image.id}",
            params: { board_image: { bg_color: "#fff" } },
            headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "DELETE /api/board_images/:id (destroy)" do
      delete "/api/board_images/#{other_board_image.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "POST /api/board_images/:id/set_current_audio" do
      post "/api/board_images/#{other_board_image.id}/set_current_audio",
           params: { board_image: { audio_url: "http://x", voice: "alloy" } },
           headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "POST /api/board_images/:id/create_edit" do
      post "/api/board_images/#{other_board_image.id}/create_edit",
           params: { prompt: "x" },
           headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "POST /api/board_images/:id/create_variation" do
      post "/api/board_images/#{other_board_image.id}/create_variation",
           headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "POST /api/board_images/:id/upload_audio" do
      post "/api/board_images/#{other_board_image.id}/upload_audio",
           headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "POST /api/board_images/:id/reset_audio" do
      post "/api/board_images/#{other_board_image.id}/reset_audio",
           headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the owner and admins are not blocked (no regression)" do
    it "lets the owner set current audio on their own tile" do
      post "/api/board_images/#{board_image.id}/set_current_audio",
           params: { board_image: { audio_url: "http://x", voice: "alloy" } },
           headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
    end

    it "lets the owner destroy their own tile" do
      delete "/api/board_images/#{board_image.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:no_content)
    end

    it "lets an admin destroy another user's tile (cross-user access preserved)" do
      delete "/api/board_images/#{other_board_image.id}", headers: auth_headers(admin)
      expect(response).to have_http_status(:no_content)
    end
  end
end
