require "rails_helper"

RSpec.describe "Admin::Users", type: :request do
  include Devise::Test::IntegrationHelpers

  let!(:admin) { create(:admin_user) }
  let!(:user1) { create(:user, email: "alice@example.com", name: "Alice") }
  let!(:user2) { create(:user, email: "bob@example.com", name: "Bob", plan_type: "pro") }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
      .to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
      .to receive(:javascript_include_tag).and_return("")
    sign_in admin
  end

  describe "GET /admin/users" do
    it "renders the users list" do
      get admin_dashboard_users_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("alice@example.com")
      expect(response.body).to include("bob@example.com")
    end

    it "filters by plan type" do
      get admin_dashboard_users_path(filter: "pro")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("bob@example.com")
      expect(response.body).not_to include("alice@example.com")
    end

    it "searches by email" do
      get admin_dashboard_users_path(search: "alice")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("alice@example.com")
      expect(response.body).not_to include("bob@example.com")
    end

    it "sorts by column" do
      get admin_dashboard_users_path(sort: "email", dir: "asc")
      expect(response).to have_http_status(:ok)
    end

    it "filters demo accounts" do
      demo = create(:user, email: "bhannajohns+test@gmail.com")
      get admin_dashboard_users_path(filter: "demo")
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("bhannajohns+test@gmail.com")
      expect(response.body).not_to include("alice@example.com")
    end

    context "when not signed in" do
      before { sign_out admin }

      it "redirects" do
        get admin_dashboard_users_path
        expect(response).to redirect_to(new_user_session_path)
      end
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in user1
      end

      it "redirects to root" do
        get admin_dashboard_users_path
        expect(response).to redirect_to(root_path)
      end
    end
  end

  describe "GET /admin/users/:id" do
    it "renders the user show page" do
      get admin_dashboard_user_path(user1)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("alice@example.com")
      expect(response.body).to include("Account")
      expect(response.body).to include("Boards")
    end

    it "shows boards for the user" do
      create(:board, user: user1, name: "Test Board")
      get admin_dashboard_user_path(user1)
      expect(response.body).to include("Test Board")
    end

    it "shows communicators for the user" do
      ca = create(:child_account, user: user1, name: "Kid", status: "active")
      get admin_dashboard_user_path(user1)
      expect(response.body).to include("Kid")
    end

    it "shows user settings" do
      user1.update(settings: { "board_limit" => 10 })
      get admin_dashboard_user_path(user1)
      expect(response.body).to include("board_limit")
    end
  end
end
