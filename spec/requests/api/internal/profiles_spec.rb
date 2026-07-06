require "rails_helper"

RSpec.describe "API::Internal::Profiles", type: :request do
  let(:internal_key) { "test-internal-key" }
  let(:auth_headers) { { "Authorization" => "Bearer #{internal_key}" } }
  let(:json_headers) { auth_headers.merge("Content-Type" => "application/json") }
  let!(:admin_user) do
    user = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
    # Inserting a row with an explicit primary key does not advance the
    # `users` sequence, so the next factory-built user (e.g. via
    # `create(:child_account)`'s `association :user`) would otherwise collide
    # on id=1. Reset the sequence to MAX(id)+1.
    ActiveRecord::Base.connection.reset_pk_sequence!("users")
    user
  end
  let(:profile_owner) { create(:child_account) }
  let!(:profile) do
    create(:profile,
           profileable: profile_owner,
           profile_kind: "safety",
           slug: "ada-lovelace",
           settings: { "allergies" => "none" })
  end

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("INTERNAL_API_KEY").and_return(internal_key)
    allow(Communicators::GenerateSafetyIdCard).to receive(:call)
    allow(Communicators::GenerateDeviceTag).to receive(:call)
  end

  describe "GET /api/internal/profiles/:id" do
    context "without a valid bearer token" do
      it "returns 401" do
        get "/api/internal/profiles/#{profile.id}"
        expect(response).to have_http_status(:unauthorized)
      end
    end

    it "returns the profile when found by id" do
      get "/api/internal/profiles/#{profile.id}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.dig("profile", "id")).to eq(profile.id)
      expect(body).to have_key("assets")
    end

    it "returns the profile when found by slug" do
      get "/api/internal/profiles/#{profile.slug}", headers: auth_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body).dig("profile", "id")).to eq(profile.id)
    end

    it "returns 404 when neither id nor slug matches" do
      get "/api/internal/profiles/does-not-exist", headers: auth_headers
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "PATCH /api/internal/profiles/:id" do
    it "returns 401 without the bearer token" do
      patch "/api/internal/profiles/#{profile.id}",
            params: { profile: { bio: "x" } }.to_json,
            headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:unauthorized)
    end

    it "updates settings and persists them" do
      new_settings = {
        "allergies" => "peanuts",
        "ice_contact_1" => { "name" => "Mom", "phone" => "555", "relationship" => "parent" },
      }

      patch "/api/internal/profiles/#{profile.id}",
            params: { profile: { settings: new_settings } }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(profile.reload.settings).to include(new_settings)
    end

    it "regenerates safety_id and device_tag attachments for safety profiles" do
      patch "/api/internal/profiles/#{profile.id}",
            params: { profile: { bio: "Updated bio" } }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(Communicators::GenerateSafetyIdCard).to have_received(:call).with(profile)
      expect(Communicators::GenerateDeviceTag).to have_received(:call).with(profile)
    end

    it "regenerates the tags pointed at qr_target_url when provided (AAC Classroom Kit)" do
      kit_url = "https://speakanyway.com/classroom?utm_content=safety_tag"

      patch "/api/internal/profiles/#{profile.id}",
            params: { qr_target_url: kit_url, profile: {} }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(Communicators::GenerateSafetyIdCard)
        .to have_received(:call).with(profile, regenerate: true, qr_target_url: kit_url)
      expect(Communicators::GenerateDeviceTag)
        .to have_received(:call).with(profile, regenerate: true, qr_target_url: kit_url)
    end

    it "accepts an empty profile patch and regenerates safety attachments" do
      patch "/api/internal/profiles/#{profile.id}",
            params: { profile: {} }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(Communicators::GenerateSafetyIdCard).to have_received(:call).with(profile)
      expect(Communicators::GenerateDeviceTag).to have_received(:call).with(profile)
    end

    it "does not regenerate attachments for non-safety profiles" do
      profile.update!(profile_kind: "public_page")

      patch "/api/internal/profiles/#{profile.id}",
            params: { profile: { bio: "Updated" } }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(Communicators::GenerateSafetyIdCard).not_to have_received(:call)
      expect(Communicators::GenerateDeviceTag).not_to have_received(:call)
    end

    it "supports lookup by slug" do
      patch "/api/internal/profiles/#{profile.slug}",
            params: { profile: { bio: "From slug" } }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:ok)
      expect(profile.reload.bio).to eq("From slug")
    end

    it "returns 404 when the profile cannot be found" do
      patch "/api/internal/profiles/nope-nope",
            params: { profile: { bio: "x" } }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:not_found)
    end

    it "returns 422 when validation fails" do
      patch "/api/internal/profiles/#{profile.id}",
            params: { profile: { username: "" } }.to_json,
            headers: json_headers

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Profile update failed")
      expect(body["details"]).to be_an(Array)
    end
  end
end
