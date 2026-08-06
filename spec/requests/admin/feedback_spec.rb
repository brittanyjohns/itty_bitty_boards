require "rails_helper"

RSpec.describe "Admin::Feedback (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "authorization" do
    it "redirects a non-admin" do
      sign_in create(:user)

      get admin_dashboard_feedback_path

      expect(response).to redirect_to(root_path)
    end

    it "redirects a signed-out visitor" do
      get admin_dashboard_feedback_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /admin/feedback" do
    it "lists all feedback by default, newest first" do
      sign_in admin
      user = create(:user, email: "reporter@example.com")
      older = create(:feedback_item, user: user, feedback_type: "bug", subject: "Old bug", created_at: 2.days.ago)
      newer = create(:feedback_item, user: user, feedback_type: "feature", subject: "New idea", created_at: 1.hour.ago)

      get admin_dashboard_feedback_path

      expect(response).to have_http_status(:ok)
      expect(response.body.index("New idea")).to be < response.body.index("Old bug")
    end

    it "filters by feedback type" do
      sign_in admin
      user = create(:user)
      create(:feedback_item, user: user, feedback_type: "bug", subject: "A bug report")
      create(:feedback_item, user: user, feedback_type: "praise", subject: "Great app")

      get admin_dashboard_feedback_path(type: "bug")

      expect(response.body).to include("A bug report")
      expect(response.body).not_to include("Great app")
    end

    it "searches across subject, message, and reporter email" do
      sign_in admin
      user = create(:user, email: "findme@example.com")
      create(:feedback_item, user: user, subject: "Unrelated subject", message: "unrelated message")
      matching = create(:feedback_item, user: user, subject: "Matches nothing", message: "nothing matches")

      get admin_dashboard_feedback_path(search: "findme")

      expect(response.body).to include(matching.subject)
    end

    it "shows the reporting user's email and a link to their admin page" do
      sign_in admin
      user = create(:user, email: "reporter@example.com")
      create(:feedback_item, user: user)

      get admin_dashboard_feedback_path

      expect(response.body).to include("reporter@example.com")
      expect(response.body).to include(admin_dashboard_user_path(user))
    end
  end
end
