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

      # Security: ORDER BY injection guard. Rails raises ActiveRecord::UnknownAttributeReference
      # in test mode (not a 500 — exceptions bubble up). These tests document the vulnerability:
      # they currently FAIL because the exception is raised. Once a sort_field allowlist is added
      # (matching the pattern in boards_controller.rb), these tests will pass.
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
end
