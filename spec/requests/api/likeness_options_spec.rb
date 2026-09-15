require "rails_helper"

# The picker renders from this so the frontend never carries its own copy of
# the token lists — a drifted copy offers choices the save silently drops.
RSpec.describe "API::LikenessOptions", type: :request do
  describe "GET /api/likeness_options" do
    it "is readable without a token" do
      get "/api/likeness_options"

      expect(response).to have_http_status(:ok)
    end

    it "serves every field's tokens in order, labelled" do
      get "/api/likeness_options"
      body = JSON.parse(response.body)

      CommunicatorLikeness::FIELDS.each do |field, values|
        expect(body["fields"][field]["options"].map { |o| o["value"] }).to eq(values)
        expect(body["fields"][field]["options"].map { |o| o["label"] }).to all(be_present)
      end
      expect(body["extras"]["options"].map { |o| o["value"] }).to eq(CommunicatorLikeness::EXTRAS)
      expect(body["fields"]["skin_tone"]["options"].map { |o| o["swatch"] }).to all(match(/\A#\h{6}\z/))
    end

    it "publishes only values a save will keep" do
      get "/api/likeness_options"
      body = JSON.parse(response.body)

      body["fields"].each do |field, spec|
        spec["options"].each do |option|
          expect(CommunicatorLikeness.from_hash(field => option["value"]).to_h).to eq(field => option["value"])
        end
      end
    end

    # The picker enforces these as the user types; a drifted copy would let a
    # write-in through the form that the save then silently drops.
    it "serves the write-in caps and character class the save enforces" do
      get "/api/likeness_options"
      custom = JSON.parse(response.body)["custom_extras"]

      expect(custom).to include(
        "max_items" => CommunicatorLikeness::CUSTOM_EXTRAS_MAX_ITEMS,
        "max_length" => CommunicatorLikeness::CUSTOM_EXTRA_MAX_LENGTH,
        "allowed_characters" => CommunicatorLikeness::CUSTOM_EXTRA_CHARACTERS,
      )
      expect(custom["label"]).to eq("Something else")
    end

    it "labels in Spanish when asked" do
      get "/api/likeness_options", params: { locale: "es" }

      expect(JSON.parse(response.body)["fields"]["skin_tone"]["label"]).to eq("Tono de piel")
    end

    it "falls back to the default locale for an unknown one" do
      get "/api/likeness_options", params: { locale: "../../etc" }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["fields"]["skin_tone"]["label"]).to eq("Skin tone")
    end
  end
end
