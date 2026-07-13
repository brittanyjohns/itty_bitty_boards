require "rails_helper"

RSpec.describe "Admin::Dashboard", type: :request do
  include Devise::Test::IntegrationHelpers

  let_it_be(:admin) { create(:admin_user) }
  let_it_be(:real_user) { create(:user, email: "real@example.com") }
  let_it_be(:demo_user) { create(:user, email: "bhannajohns+dash@gmail.com") }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
      .to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper)
      .to receive(:javascript_include_tag).and_return("")
    sign_in admin
  end

  describe "GET /admin" do
    it "counts users excluding admins and demo accounts" do
      get admin_root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Total Users")
      # real_user only — admin and demo_user excluded
      expect(response.body).to match(/Total Users.*?>1</m)
    end

    it "counts boards excluding demo-owned ones" do
      create(:board, user: real_user)
      create(:board, user: demo_user)

      get admin_root_path

      expect(response.body).to match(/Total Boards.*?>1</m)
    end

    it "shows the demo account count with a cleanup link" do
      get admin_root_path

      expect(response.body).to include("Demo Accounts")
      expect(response.body).to include(admin_dashboard_users_path(filter: "demo"))
    end

    context "when signed in as non-admin" do
      before do
        sign_out admin
        sign_in real_user
      end

      it "redirects to root" do
        get admin_root_path
        expect(response).to redirect_to(root_path)
      end
    end
  end
end
