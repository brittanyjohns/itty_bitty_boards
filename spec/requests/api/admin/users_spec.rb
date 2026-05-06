require "rails_helper"

RSpec.describe "API::Admin::Users", type: :request do
  let!(:admin) { create(:admin_user) }
  let!(:user)  { create(:user) }

  describe "GET /api/admin/users" do
    context "when unauthenticated" do
      it "returns 401" do
        get "/api/admin/users"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as a non-admin user" do
      it "returns 401" do
        get "/api/admin/users", headers: auth_headers(user)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as an admin" do
      it "returns 200" do
        get "/api/admin/users", headers: auth_headers(admin)
        expect(response).to have_http_status(:ok)
      end

      it "returns a list of users" do
        get "/api/admin/users", headers: auth_headers(admin)
        expect(JSON.parse(response.body)).to be_a(Array)
      end

      it "accepts valid sort params" do
        get "/api/admin/users",
            params: { sort_field: "created_at", sort_order: "desc" },
            headers: auth_headers(admin)
        expect(response).to have_http_status(:ok)
      end

      it "does not raise an error when sort_field contains a SQL injection payload" do
        expect {
          get "/api/admin/users",
              params: { sort_field: "role; DROP TABLE users;--", sort_order: "asc" },
              headers: auth_headers(admin)
        }.not_to raise_error
      end
    end
  end

  describe "GET /api/admin/users/:id" do
    context "when unauthenticated" do
      it "returns 401" do
        get "/api/admin/users/#{user.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as admin" do
      it "returns the user" do
        get "/api/admin/users/#{user.id}", headers: auth_headers(admin)
        expect(response).to have_http_status(:ok)
        expect(JSON.parse(response.body)["id"]).to eq(user.id)
      end
    end
  end
end
