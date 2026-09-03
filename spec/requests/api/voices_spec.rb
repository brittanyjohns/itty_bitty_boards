require "rails_helper"

RSpec.describe "API voices", type: :request do
  let(:user) { create(:user) }

  describe "GET /api/voices" do
    it "returns the full catalogue" do
      get "/api/voices", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["voices"]).to be_an(Array)
      expect(body["voices"]).not_to be_empty
      expect(body["labels"]).to be_an(Array)
    end

    # A picker that seeds itself with a hardcoded voice submits that value, at
    # which point the server can no longer tell a form default from a
    # deliberate pick. The default has to be resolved before the picker renders,
    # which is what this field is for.
    it "answers with the band's default voice" do
      get "/api/voices", params: { age_band: "15-18" }, headers: auth_headers(user)

      body = JSON.parse(response.body)
      expect(body["default_voice"]).to eq(VoiceService.default_for_age_band("15-18"))
      expect(VoiceService.get_voice(body["default_voice"])[:tags]).not_to include("kid")
    end

    it "still defaults to the app-wide voice with no band" do
      get "/api/voices", headers: auth_headers(user)

      expect(JSON.parse(response.body)["default_voice"]).to eq(VoiceService::DEFAULT_VOICE)
    end

    # Free sees exactly one option in the picker, so this description is the
    # only thing a 17-year-old's family reads about the voice they are given.
    it "describes no voice as being for children" do
      get "/api/voices", headers: auth_headers(user)

      JSON.parse(response.body)["voices"].each do |voice|
        expect(voice["description"].to_s.downcase).not_to match(/\b(kid|kids|child|children)\b/),
                                                          "#{voice["label"]}: #{voice["description"]}"
      end
    end
  end
end
