require "rails_helper"

RSpec.describe "Admin::Events (dashboard)", type: :request do
  include Devise::Test::IntegrationHelpers

  let(:admin) { create(:admin_user) }

  before do
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:stylesheet_link_tag).and_return("")
    allow_any_instance_of(ActionView::Helpers::AssetTagHelper).to receive(:javascript_include_tag).and_return("")
  end

  describe "authorization" do
    it "redirects a non-admin away from every action" do
      sign_in create(:user)
      event = create(:event)

      get admin_dashboard_events_path
      expect(response).to redirect_to(root_path)

      get admin_dashboard_event_path(event)
      expect(response).to redirect_to(root_path)
    end

    it "redirects a signed-out visitor" do
      get admin_dashboard_events_path
      expect(response).to redirect_to(new_user_session_path)
    end
  end

  describe "GET /admin/events" do
    it "lists events" do
      sign_in admin
      create(:event, name: "Spring Giveaway")

      get admin_dashboard_events_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Spring Giveaway")
    end
  end

  describe "GET /admin/events/:id" do
    it "shows event detail, entries, and a QR code for the public entry URL" do
      sign_in admin
      event = create(:event, name: "Spring Giveaway")
      create(:contest_entry, event: event, name: "Alice", email: "alice@example.com")

      get admin_dashboard_event_path(event)

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Spring Giveaway")
      expect(response.body).to include("Alice")
      expect(response.body).to include("data:image/png;base64,")
    end
  end

  describe "POST /admin/events" do
    it "creates an event" do
      sign_in admin

      expect {
        post admin_dashboard_events_path, params: { event: { name: "New Event" } }
      }.to change(Event, :count).by(1)

      expect(response).to redirect_to(admin_dashboard_event_path(Event.last))
    end

    it "re-renders the form on validation failure" do
      sign_in admin

      expect {
        post admin_dashboard_events_path, params: { event: { name: "" } }
      }.not_to change(Event, :count)

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "PUT /admin/events/:id" do
    it "updates an event" do
      sign_in admin
      event = create(:event, name: "Old Name")

      put admin_dashboard_event_path(event), params: { event: { name: "New Name" } }

      expect(response).to redirect_to(admin_dashboard_event_path(event))
      expect(event.reload.name).to eq("New Name")
    end
  end

  describe "POST /admin/events/:id/pick_winner" do
    it "picks a winner from the entries and clears any previous winner" do
      sign_in admin
      event = create(:event)
      old_winner = create(:contest_entry, event: event, winner: true)
      create(:contest_entry, event: event)

      post pick_winner_admin_dashboard_event_path(event)

      expect(response).to redirect_to(admin_dashboard_event_path(event))
      expect(event.contest_entries.where(winner: true).count).to eq(1)
      expect(event.winner).to be_present
    end

    it "alerts instead of erroring when there are no entries" do
      sign_in admin
      event = create(:event)

      post pick_winner_admin_dashboard_event_path(event)

      expect(response).to redirect_to(admin_dashboard_event_path(event))
      follow_redirect!
      expect(response.body).to include("No entries")
    end
  end

  describe "GET /admin/events/:id/download_entries" do
    it "streams a CSV of entries" do
      sign_in admin
      event = create(:event)
      create(:contest_entry, event: event, name: "Alice", email: "alice@example.com")

      get download_entries_admin_dashboard_event_path(event)

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("text/csv")
      expect(response.body).to include("alice@example.com")
    end
  end
end
