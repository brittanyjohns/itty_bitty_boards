require "rails_helper"

RSpec.describe "API::Images", type: :request do
  let!(:user)       { create(:user) }
  let!(:other_user) { create(:user) }
  let!(:image)      { create(:image, user: user) }
  let!(:other_image){ create(:image, user: other_user) }

  describe "GET /api/images" do
    context "when unauthenticated" do
      it "returns 401" do
        get "/api/images"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated" do
      it "returns 200" do
        get "/api/images", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "returns a JSON array" do
        get "/api/images", headers: auth_headers(user)
        expect(JSON.parse(response.body)).to be_a(Array)
      end

      it "accepts valid sort_field and sort_order without error" do
        get "/api/images", params: { sort_field: "label", sort_order: "asc" },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "accepts created_at as sort_field" do
        get "/api/images", params: { sort_field: "created_at", sort_order: "desc" },
            headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end

      it "does not raise an error when sort_field contains a SQL injection payload" do
        expect {
          get "/api/images",
              params: { sort_field: "id; DROP TABLE images; --", sort_order: "asc" },
              headers: auth_headers(user)
        }.not_to raise_error
      end

      it "does not raise an error when sort_order contains an invalid value" do
        expect {
          get "/api/images",
              params: { sort_field: "label", sort_order: "INVALID; --" },
              headers: auth_headers(user)
        }.not_to raise_error
      end
    end
  end

  describe "GET /api/images/:id" do
    context "when unauthenticated" do
      it "returns 401" do
        get "/api/images/#{image.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated" do
      it "returns 200 for any image (images are not private by user at this level)" do
        get "/api/images/#{image.id}", headers: auth_headers(user)
        expect(response).to have_http_status(:ok)
      end
    end
  end

  # Issue #26 (IDOR): resource lookups must be scoped so a caller can't load
  # another user's PRIVATE image by guessing its id. Images are a shared
  # library, so PUBLIC images (is_private false/nil) and the caller's own
  # images stay reachable; only another user's private image 404s.
  describe "IDOR — image lookups scoped to accessible images" do
    let!(:admin)              { create(:admin_user) }
    let!(:other_private_image) { create(:image, user: other_user, is_private: true) }
    let!(:public_image)        { create(:image, user: other_user, is_private: false) }

    # Endpoints that build/enrich the shared library: own OR public reachable,
    # another user's private image => 404.
    describe "accessible-scoped endpoints reject a non-owner's private image with 404" do
      it "POST /api/images/crop" do
        post "/api/images/crop",
             params: { image: { id: other_private_image.id, label: "x" }, file_extension: "png" },
             headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end

      it "POST /api/images/save_temp_doc" do
        post "/api/images/save_temp_doc",
             params: { imageId: other_private_image.id, query: "x" },
             headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end

      it "POST /api/images/:id/add_doc" do
        post "/api/images/#{other_private_image.id}/add_doc",
             params: { image: { label: "x" } },
             headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end

      it "POST /api/images/:id/create_predictive_board" do
        post "/api/images/#{other_private_image.id}/create_predictive_board",
             headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end

      it "POST /api/images/:id/create_symbol" do
        post "/api/images/#{other_private_image.id}/create_symbol",
             headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end

      it "POST /api/images/generate" do
        post "/api/images/generate",
             params: { id: other_private_image.id, image: { label: "x", image_prompt: "a longer prompt" } },
             headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end

      it "GET /api/images/:id/prompt_suggestion" do
        get "/api/images/#{other_private_image.id}/prompt_suggestion",
            headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end

      it "POST /api/images/:id/clear_current" do
        post "/api/images/#{other_private_image.id}/clear_current",
             headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end

      it "POST /api/images/:id/hide_doc" do
        post "/api/images/#{other_private_image.id}/hide_doc",
             params: { doc_id: 0 },
             headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end
    end

    describe "shared library stays reachable (no regression)" do
      # update_all avoids an unrelated pre-existing crash in clear_current when
      # called with no board_id (it dereferences a nil @board); the accessible
      # scope is what we're exercising here.
      it "lets a non-owner act on a PUBLIC image (not 404)" do
        post "/api/images/#{public_image.id}/clear_current",
             params: { update_all: true }, headers: auth_headers(user)
        expect(response).not_to have_http_status(:not_found)
        expect(response).to have_http_status(:ok)
      end

      it "lets the owner act on their own image (not 404)" do
        post "/api/images/#{image.id}/clear_current",
             params: { update_all: true }, headers: auth_headers(user)
        expect(response).not_to have_http_status(:not_found)
        expect(response).to have_http_status(:ok)
      end

      it "lets an admin act cross-user on a private image (not 404)" do
        post "/api/images/#{other_private_image.id}/clear_current",
             params: { update_all: true }, headers: auth_headers(admin)
        expect(response).not_to have_http_status(:not_found)
        expect(response).to have_http_status(:ok)
      end
    end

    # destroy_audio is owner-only (destructive), so even a PUBLIC image owned by
    # someone else is off-limits — matches upload_audio/set_current_audio.
    describe "owner-only DELETE /api/images/:id/destroy_audio" do
      it "404s for a non-owner even on a public image" do
        delete "/api/images/#{public_image.id}/destroy_audio",
               params: { audio_file_id: 1 },
               headers: auth_headers(user)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
