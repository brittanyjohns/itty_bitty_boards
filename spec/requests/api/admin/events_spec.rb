require "rails_helper"

RSpec.describe "API::Admin::Events", type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:event) { FactoryBot.create(:event, name: "Spring Giveaway 2026", slug: "spring-giveaway-2026") }
  let!(:loser) { FactoryBot.create(:contest_entry, event: event, name: "Loser", email: "loser@example.com") }
  let!(:winner) { FactoryBot.create(:contest_entry, event: event, name: "Winner", email: "winner@example.com", winner: true) }

  describe "GET /api/admin/events/:id_or_slug" do
    it "returns the admin view, including entries and winner fields" do
      get "/api/admin/events/#{event.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.keys).to include(
        "id", "name", "slug", "date", "promo_code", "promo_code_details", "public_url",
        "created_at", "updated_at", "entries_count", "winner", "winner_name",
        "winner_email", "contest_entries"
      )
      expect(body["entries_count"]).to eq(2)
      expect(body["winner_name"]).to eq("Winner")
      expect(body["winner_email"]).to eq("winner@example.com")
      expect(body["winner"]["id"]).to eq(winner.id)
      expect(body["contest_entries"].map { |e| e["email"] })
        .to match_array(%w[loser@example.com winner@example.com])
      expect(body["contest_entries"].first.keys).to match_array(
        %w[id name email data event_id winner created_at updated_at],
      )
    end

    it "orders contest_entries newest first" do
      older = FactoryBot.create(:contest_entry, event: event, email: "older@example.com", created_at: 3.days.ago)
      newer = FactoryBot.create(:contest_entry, event: event, email: "newer@example.com", created_at: 1.minute.ago)

      get "/api/admin/events/#{event.slug}", headers: auth_headers(admin)

      ids = JSON.parse(response.body)["contest_entries"].map { |e| e["id"] }
      expect(ids.index(newer.id)).to be < ids.index(older.id)
    end

    it "resolves the event by slug as well as by id" do
      get "/api/admin/events/#{event.slug}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["id"]).to eq(event.id)
    end

    it "reports no winner as null when nobody has been drawn" do
      event.contest_entries.update_all(winner: false)

      get "/api/admin/events/#{event.slug}", headers: auth_headers(admin)

      body = JSON.parse(response.body)
      expect(body["winner"]).to be_nil
      expect(body["winner_name"]).to be_nil
      expect(body["winner_email"]).to be_nil
    end

    it "404s with the exact not_found error when neither a slug nor an id matches" do
      get "/api/admin/events/no-such-event", headers: auth_headers(admin)

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq({ "error" => "not_found" })
    end

    it "401s with the exact Unauthorized error without a token" do
      get "/api/admin/events/#{event.slug}"

      expect(response).to have_http_status(:unauthorized)
      expect(JSON.parse(response.body)).to eq({ "error" => "Unauthorized" })
      expect(response.body).not_to include("winner@example.com")
    end

    it "401s for a signed-in non-admin" do
      get "/api/admin/events/#{event.slug}", headers: auth_headers(FactoryBot.create(:user))

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include("winner@example.com")
    end
  end
end
