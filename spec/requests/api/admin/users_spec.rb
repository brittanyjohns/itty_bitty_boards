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

  describe "POST /api/admin/users/:id/adjust_credits" do
    before { reset_user_credits!(user) }

    context "when unauthenticated" do
      it "returns 401" do
        post "/api/admin/users/#{user.id}/adjust_credits", params: { amount: 100 }
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as non-admin" do
      it "returns 401" do
        post "/api/admin/users/#{user.id}/adjust_credits",
             params: { amount: 100 },
             headers: auth_headers(user)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as admin" do
      it "adds plan credits" do
        post "/api/admin/users/#{user.id}/adjust_credits",
             params: { amount: 100, source: "plan", reason: "testing" },
             headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["success"]).to be true
        expect(body["balance"]["plan"]).to eq(100)
        expect(user.reload.plan_credits_balance).to eq(100)
      end

      it "adds topup credits" do
        post "/api/admin/users/#{user.id}/adjust_credits",
             params: { amount: 50, source: "topup" },
             headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["balance"]["topup"]).to eq(50)
      end

      it "removes credits with negative amount" do
        CreditService.grant_plan!(user, amount: 200, period_end: 30.days.from_now)

        post "/api/admin/users/#{user.id}/adjust_credits",
             params: { amount: -50, source: "plan" },
             headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        expect(user.reload.plan_credits_balance).to eq(150)
      end

      it "defaults source to plan" do
        post "/api/admin/users/#{user.id}/adjust_credits",
             params: { amount: 25 },
             headers: auth_headers(admin)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["balance"]["plan"]).to eq(25)
      end

      it "rejects zero amount" do
        post "/api/admin/users/#{user.id}/adjust_credits",
             params: { amount: 0 },
             headers: auth_headers(admin)

        expect(response).to have_http_status(:unprocessable_content)
      end

      it "rejects adjustment that would make balance negative" do
        post "/api/admin/users/#{user.id}/adjust_credits",
             params: { amount: -999, source: "plan" },
             headers: auth_headers(admin)

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe "DELETE /api/admin/users/cleanup_demo" do
    let!(:demo1) { create(:user, email: "bhannajohns+one@gmail.com") }
    let!(:demo2) { create(:user, email: "bhannajohns+two@gmail.com") }
    let!(:demo_with_boards) { create(:user, email: "test@speakanyway.com") }

    before do
      2.times { create(:board, user: demo_with_boards) }
    end

    context "when unauthenticated" do
      it "returns 401" do
        delete "/api/admin/users/cleanup_demo"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as non-admin" do
      it "returns 401" do
        delete "/api/admin/users/cleanup_demo", headers: auth_headers(user)
        expect(response).to have_http_status(:unauthorized)
      end
    end

    context "when authenticated as admin" do
      it "deletes demo users keeping top N by board count" do
        expect {
          delete "/api/admin/users/cleanup_demo",
                 params: { keep_count: 1 },
                 headers: auth_headers(admin)
        }.to change(User, :count).by(-2)

        expect(response).to have_http_status(:ok)
        body = JSON.parse(response.body)
        expect(body["deleted_count"]).to eq(2)
        expect(body["preserved_count"]).to eq(1)
        expect(User.exists?(demo_with_boards.id)).to be true
      end

      it "respects exclude_ids" do
        expect {
          delete "/api/admin/users/cleanup_demo",
                 params: { keep_count: 1, exclude_ids: [demo1.id] },
                 headers: auth_headers(admin)
        }.to change(User, :count).by(-1)

        expect(User.exists?(demo1.id)).to be true
        expect(User.exists?(demo_with_boards.id)).to be true
      end

      it "never includes admin accounts in demo cleanup" do
        admin_demo = create(:admin_user, email: "bhannajohns+admin@gmail.com")

        delete "/api/admin/users/cleanup_demo",
               params: { keep_count: 0 },
               headers: auth_headers(admin)

        expect(User.exists?(admin_demo.id)).to be true
      end

      it "never touches non-demo users" do
        delete "/api/admin/users/cleanup_demo",
               params: { keep_count: 0 },
               headers: auth_headers(admin)

        expect(User.exists?(user.id)).to be true
        expect(User.exists?(admin.id)).to be true
      end
    end
  end
end
