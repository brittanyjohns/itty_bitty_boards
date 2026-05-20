require "rails_helper"

RSpec.describe "API::Audits communicator_stats", type: :request do
  let!(:user) { create(:user) }
  let!(:account) { create(:child_account, user: user) }

  def create_event(attrs = {})
    create(:word_event, { user: user, child_account: account }.merge(attrs))
  end

  describe "GET /api/word_events/stats" do
    it "requires authentication" do
      get "/api/word_events/stats", params: { account_id: account.id }
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 404 when the account does not exist" do
      get "/api/word_events/stats", params: { account_id: 999_999_999 }, headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end

    it "returns the bundled stats payload for the account" do
      create_event(word: "hello", timestamp: 1.day.ago)
      create_event(word: "hello", timestamp: 1.day.ago)
      create_event(word: "hello", timestamp: 1.day.ago)
      create_event(word: "bye", timestamp: 1.day.ago)

      get "/api/word_events/stats", params: { account_id: account.id, days: 90 }, headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)

      expect(body["range"]["days"]).to eq(90)
      expect(body["summary"]["total_events"]).to eq(4)
      expect(body["summary"]["unique_words"]).to eq(2)
      expect(body["summary"]["active_days"]).to eq(1)
      expect(body["summary"]["most_active_day"]["count"]).to eq(4)
      expect(body["summary"]["top_word"]).to eq("word" => "hello", "count" => 3)
      expect(body["events"].size).to eq(4)
      expect(body["heat_map"]).to be_an(Array)
      expect(body["most_clicked_words"].first).to eq("word" => "hello", "count" => 3)
    end

    it "only counts word events belonging to the requested account" do
      other_account = create(:child_account, user: user)
      create_event(word: "mine", timestamp: 1.day.ago)
      create(:word_event, user: user, child_account: other_account, word: "theirs", timestamp: 1.day.ago)

      get "/api/word_events/stats", params: { account_id: account.id, days: 90 }, headers: auth_headers(user)

      body = JSON.parse(response.body)
      expect(body["summary"]["total_events"]).to eq(1)
      expect(body["events"].map { |e| e["word"] }).to eq(["mine"])
    end

    it "excludes events outside the selected day range" do
      create_event(word: "recent", timestamp: 10.days.ago)
      create_event(word: "stale", timestamp: 200.days.ago)

      get "/api/word_events/stats", params: { account_id: account.id, days: 90 }, headers: auth_headers(user)
      body = JSON.parse(response.body)
      expect(body["summary"]["total_events"]).to eq(1)

      get "/api/word_events/stats", params: { account_id: account.id, days: 365 }, headers: auth_headers(user)
      body = JSON.parse(response.body)
      expect(body["summary"]["total_events"]).to eq(2)
    end

    it "falls back to the default range for an invalid days value" do
      get "/api/word_events/stats", params: { account_id: account.id, days: 9999 }, headers: auth_headers(user)
      expect(JSON.parse(response.body)["range"]["days"]).to eq(180)
    end

    it "breaks down events by the linked image's part of speech" do
      noun = create(:image).tap { |i| i.update_columns(part_of_speech: "noun") }
      verb = create(:image).tap { |i| i.update_columns(part_of_speech: "verb") }
      create_event(word: "dog", image: noun, timestamp: 1.day.ago)
      create_event(word: "cat", image: noun, timestamp: 1.day.ago)
      create_event(word: "run", image: verb, timestamp: 1.day.ago)

      get "/api/word_events/stats", params: { account_id: account.id, days: 90 }, headers: auth_headers(user)
      breakdown = JSON.parse(response.body)["part_of_speech_breakdown"]
      expect(breakdown).to contain_exactly(
        { "label" => "noun", "count" => 2 },
        { "label" => "verb", "count" => 1 },
      )
    end
  end
end
