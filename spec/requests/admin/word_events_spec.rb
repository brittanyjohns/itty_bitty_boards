require "rails_helper"

RSpec.describe "Admin::WordEvents (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "authorization" do
    it "redirects a non-admin" do
      sign_in create(:user)

      get admin_dashboard_word_events_path

      expect(response).to redirect_to(root_path)
    end

    it "redirects a signed-out visitor" do
      get admin_dashboard_word_events_path

      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /admin/word_events" do
    it "lists word events for other users" do
      sign_in admin
      user = create(:user, email: "speaker@example.com")
      create(:word_event, user: user, word: "hello")

      get admin_dashboard_word_events_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("hello")
      expect(response.body).to include("speaker@example.com")
    end

    it "excludes the current admin's own word events" do
      sign_in admin
      create(:word_event, user: admin, word: "adminword")
      other = create(:user)
      create(:word_event, user: other, word: "otherword")

      get admin_dashboard_word_events_path

      expect(response.body).not_to include("adminword")
      expect(response.body).to include("otherword")
    end

    it "sorts by the requested column and direction" do
      sign_in admin
      user = create(:user)
      create(:word_event, user: user, word: "aaa", created_at: 2.days.ago)
      create(:word_event, user: user, word: "zzz", created_at: 1.hour.ago)

      get admin_dashboard_word_events_path(sort: "word", dir: "asc")

      expect(response).to have_http_status(:ok)
      expect(response.body.index("aaa")).to be < response.body.index("zzz")
    end
  end
end
