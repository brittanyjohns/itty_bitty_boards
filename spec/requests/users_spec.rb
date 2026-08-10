require "rails_helper"

RSpec.describe "UsersController (legacy HTML profile)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:user) { create(:user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
    sign_in user
  end

  describe "the self-service profile pages" do
    it "renders show" do
      get user_path(user)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("User Profile")
    end

    it "renders edit" do
      get edit_user_path(user)

      expect(response).to have_http_status(:ok)
    end

    it "updates the user" do
      patch user_path(user), params: { user: { name: "Renamed" } }

      expect(response).to redirect_to(user_path(user))
      expect(user.reload.name).to eq("Renamed")
    end
  end

  describe "the removed admin listings" do
    def recognize(path)
      Rails.application.routes.recognize_path(path, method: :get)
    end

    it "no longer defines the actions" do
      expect(UsersController.action_methods).not_to include("index", "admin", "word_events")
    end

    it "has no /users index route (falls through to the catch-all)" do
      expect(recognize("/users")).to include(controller: "error", action: "not_found")
    end

    it "treats /users/admin as a show id, not the removed admin action" do
      expect(recognize("/users/admin")).to eq(controller: "users", action: "show", id: "admin")
    end
  end
end
