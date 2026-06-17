require "rails_helper"

RSpec.describe "API::CoachingPrompts", type: :request do
  let!(:user)  { create(:user) }
  let!(:other) { create(:user) }

  let!(:snack) do
    create(:coaching_prompt_set,
      slug: "snack_time_test",
      name: "Snack Time Test",
      match_tags: %w[snack snack_time],
      published: true,
      user_id: nil)
  end

  let!(:my_set) do
    create(:coaching_prompt_set,
      slug: "user-mine",
      name: "My Custom Set",
      user_id: user.id,
      source: "curated",
      published: true)
  end

  let!(:other_user_set) do
    create(:coaching_prompt_set,
      slug: "user-other",
      name: "Other User Set",
      user_id: other.id,
      source: "curated",
      published: true)
  end

  describe "GET /api/coaching_prompts" do
    it "requires auth" do
      get "/api/coaching_prompts"
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns SpeakAnyWay sets + own sets, not other users'" do
      get "/api/coaching_prompts", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      slugs = JSON.parse(response.body).map { |r| r["slug"] }
      expect(slugs).to include("snack_time_test", "user-mine")
      expect(slugs).not_to include("user-other")
    end
  end

  describe "GET /api/coaching_prompts?board_id=:id" do
    let(:board) { create(:board, user: user, tags: ["snack_time"]) }

    it "returns the curated prompt set when the board has a matching tag" do
      get "/api/coaching_prompts", params: { board_id: board.id }, headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      json = JSON.parse(response.body)
      expect(json["slug"]).to eq("snack_time_test")
    end

    it "404s when the board does not exist" do
      get "/api/coaching_prompts", params: { board_id: 999_999_999 }, headers: auth_headers(user)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/coaching_prompts" do
    it "creates a curated set owned by the current user" do
      params = {
        coaching_prompt_set: {
          name: "Bath Time",
          description: "Splashy fun talk",
          match_tags: ["bath"],
          strategies: [
            { label: "Pause and wait", hint: "Count to five.", example_phrases: ["I'll wait."] },
          ],
        },
      }
      expect {
        post "/api/coaching_prompts", params: params, headers: auth_headers(user), as: :json
      }.to change(CoachingPromptSet, :count).by(1)

      expect(response).to have_http_status(:created)
      created = CoachingPromptSet.order(:id).last
      expect(created.user_id).to eq(user.id)
      expect(created.source).to eq("curated")
      expect(created.slug).to include("user_#{user.id}_")
    end
  end

  describe "PATCH /api/coaching_prompts/:id" do
    it "allows the owner to update their set" do
      patch "/api/coaching_prompts/#{my_set.id}",
        params: { coaching_prompt_set: { name: "Renamed" } },
        headers: auth_headers(user),
        as: :json

      expect(response).to have_http_status(:ok)
      expect(my_set.reload.name).to eq("Renamed")
    end

    it "forbids editing another user's set" do
      patch "/api/coaching_prompts/#{other_user_set.id}",
        params: { coaching_prompt_set: { name: "Hacked" } },
        headers: auth_headers(user),
        as: :json

      expect(response).to have_http_status(:forbidden)
      expect(other_user_set.reload.name).to eq("Other User Set")
    end

    it "forbids editing a SpeakAnyWay-shipped set" do
      patch "/api/coaching_prompts/#{snack.id}",
        params: { coaching_prompt_set: { name: "Hacked" } },
        headers: auth_headers(user),
        as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "GET /api/coaching_prompts/audio" do
    before do
      io = StringIO.new("FAKE_MP3")
      allow(CoachingPhraseAudio).to receive(:synthesize).and_return(io)
    end

    it "requires auth" do
      get "/api/coaching_prompts/audio", params: { text: "Hi", voice: "polly:kevin" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "400s on blank text" do
      get "/api/coaching_prompts/audio",
        params: { text: "", voice: "polly:kevin" },
        headers: auth_headers(user)
      expect(response).to have_http_status(:bad_request)
    end

    it "422s on text > 500 chars" do
      get "/api/coaching_prompts/audio",
        params: { text: "x" * 501, voice: "polly:kevin" },
        headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "returns the audio URL and caches the row" do
      expect {
        get "/api/coaching_prompts/audio",
          params: { text: "Which one?", voice: "polly:kevin" },
          headers: auth_headers(user)
      }.to change(CoachingPhraseAudio, :count).by(1)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["url"]).to be_present
      expect(body["text"]).to eq("Which one?")
      expect(body["voice"]).to eq("polly:kevin")
    end

    it "does not re-synthesize on the second request for the same tuple" do
      get "/api/coaching_prompts/audio",
        params: { text: "Which one?", voice: "polly:kevin" },
        headers: auth_headers(user)

      expect(CoachingPhraseAudio).not_to receive(:synthesize)
      expect {
        get "/api/coaching_prompts/audio",
          params: { text: "Which one?", voice: "polly:kevin" },
          headers: auth_headers(user)
      }.not_to change(CoachingPhraseAudio, :count)

      expect(response).to have_http_status(:ok)
    end

    it "503s when synthesis returns nil" do
      allow(CoachingPhraseAudio).to receive(:synthesize).and_return(nil)
      get "/api/coaching_prompts/audio",
        params: { text: "Will fail", voice: "polly:kevin" },
        headers: auth_headers(user)
      expect(response).to have_http_status(:service_unavailable)
    end
  end

  describe "DELETE /api/coaching_prompts/:id" do
    it "allows the owner to delete" do
      expect {
        delete "/api/coaching_prompts/#{my_set.id}", headers: auth_headers(user)
      }.to change(CoachingPromptSet, :count).by(-1)
      expect(response).to have_http_status(:no_content)
    end

    it "forbids deleting another user's set" do
      expect {
        delete "/api/coaching_prompts/#{other_user_set.id}", headers: auth_headers(user)
      }.not_to change(CoachingPromptSet, :count)
      expect(response).to have_http_status(:forbidden)
    end
  end
end
