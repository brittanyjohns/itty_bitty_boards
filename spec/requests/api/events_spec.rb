require "rails_helper"

# Public, unauthenticated events API. See brittanyjohns/itty_bitty_boards#908:
# this endpoint must never leak entrant PII.
RSpec.describe "API::Events", type: :request do
  let(:event) { FactoryBot.create(:event, name: "Spring Giveaway 2026", slug: "spring-giveaway-2026") }

  describe "GET /api/events/:slug" do
    it "returns only the public fields" do
      get "/api/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.keys).to match_array(
        %w[id name slug date promo_code promo_code_details public_url created_at updated_at],
      )
      expect(body["id"]).to eq(event.id)
      expect(body["slug"]).to eq("spring-giveaway-2026")
    end

    it "never includes contest_entries, winner_name or winner_email, even when entries and a winner exist" do
      FactoryBot.create(:contest_entry, event: event, name: "Loser", email: "loser@example.com")
      FactoryBot.create(:contest_entry, event: event, name: "Winner", email: "winner@example.com", winner: true)

      get "/api/events/#{event.slug}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body).not_to have_key("contest_entries")
      expect(body).not_to have_key("winner")
      expect(body).not_to have_key("winner_name")
      expect(body).not_to have_key("winner_email")
      expect(body).not_to have_key("entries_count")
      expect(response.body).not_to include("winner@example.com")
      expect(response.body).not_to include("loser@example.com")
    end

    it "404s with the exact not_found error for an unknown slug" do
      get "/api/events/nope-not-a-real-event"

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq({ "error" => "not_found" })
    end
  end

  describe "POST /api/events/:slug/save_entry" do
    it "creates the entry and echoes only that entrant back" do
      FactoryBot.create(:contest_entry, event: event, name: "Someone Else", email: "someone.else@example.com")

      expect {
        post "/api/events/#{event.slug}/save_entry",
             params: { contest_entry: { name: "Ada Lovelace", email: "ada@example.com" } }
      }.to change { event.contest_entries.count }.by(1)

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(true)
      expect(body["entry"].keys).to match_array(
        %w[id name email data event_id winner created_at updated_at],
      )
      expect(body["entry"]["name"]).to eq("Ada Lovelace")
      expect(body["entry"]["email"]).to eq("ada@example.com")
      expect(body["entry"]["event_id"]).to eq(event.id)
      expect(body["entry"]["winner"]).to be(false)
      expect(response.body).not_to include("someone.else@example.com")
    end

    it "422s with field errors when the email has already entered this event" do
      FactoryBot.create(:contest_entry, event: event, name: "Ada", email: "ada@example.com")

      expect {
        post "/api/events/#{event.slug}/save_entry",
             params: { contest_entry: { name: "Ada Again", email: "ada@example.com" } }
      }.not_to(change { event.contest_entries.count })

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["success"]).to be(false)
      expect(body["errors"]["email"]).to include("has already entered this event")
    end

    it "404s (not 500) for an unknown slug" do
      post "/api/events/nope-not-a-real-event/save_entry",
           params: { contest_entry: { name: "Ada", email: "ada@example.com" } }

      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)).to eq({ "error" => "not_found" })
    end
  end
end
