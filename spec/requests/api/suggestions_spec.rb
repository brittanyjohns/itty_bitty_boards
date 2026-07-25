require "rails_helper"

RSpec.describe "API::Suggestions", type: :request do
  let(:user) { create(:user) }
  let(:other_user) { create(:user) }
  let(:communicator) { create(:child_account, user: user, name: "Sam") }
  let(:profile) { create(:profile, profileable: communicator) }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  def post_suggestions(body, request_headers = headers)
    post "/api/suggestions", params: body.to_json, headers: request_headers
  end

  before do
    allow(Suggestions::Generator).to receive(:call)
      .and_return(["Loves trains.", "Waves hello.", "Draws daily."])
  end

  describe "POST /api/suggestions" do
    it "returns suggestions for a profile the user owns" do
      post_suggestions(field_key: "profile_about_me", subject_id: profile.id)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["suggestions"]).to eq([
        { "text" => "Loves trains." },
        { "text" => "Waves hello." },
        { "text" => "Draws daily." },
      ])
    end

    it "returns 401 without a token" do
      post_suggestions({ field_key: "profile_about_me", subject_id: profile.id },
                       { "Content-Type" => "application/json" })

      expect(response).to have_http_status(:unauthorized)
    end

    it "returns 403 not_owner for a profile the user cannot edit" do
      post_suggestions(
        { field_key: "profile_about_me", subject_id: profile.id },
        auth_headers(other_user).merge("Content-Type" => "application/json"),
      )

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_owner")
    end

    it "returns 403 suggestions_disabled when the user turned the feature off" do
      user.update!(settings: (user.settings || {}).merge("ai_writing_suggestions" => false))

      post_suggestions(field_key: "profile_about_me", subject_id: profile.id)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("suggestions_disabled")
    end

    it "treats an absent toggle as enabled" do
      user.update!(settings: (user.settings || {}).except("ai_writing_suggestions"))

      post_suggestions(field_key: "profile_about_me", subject_id: profile.id)

      expect(response).to have_http_status(:ok)
    end

    it "returns 422 for an unknown field_key" do
      post_suggestions(field_key: "nope", subject_id: profile.id)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("unknown_field")
    end

    it "returns 200 with an empty array when the generator fails" do
      allow(Suggestions::Generator).to receive(:call).and_return([])

      post_suggestions(field_key: "profile_about_me", subject_id: profile.id)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["suggestions"]).to eq([])
    end

    it "passes the requested locale through to the generator" do
      expect(Suggestions::Generator).to receive(:call)
        .with(anything, hash_including(locale: "es")).and_return([])

      post_suggestions(field_key: "profile_about_me", subject_id: profile.id, locale: "es")
    end

    it "accepts the onboarding variant with inline context and no subject" do
      expect(Suggestions::Generator).to receive(:call)
        .with(anything, hash_including(context: { name: "Sam" })).and_return([])

      post_suggestions(
        field_key: "onboarding_about_me",
        inline_context: { name: "Sam", emergency_notes: "has seizures" },
      )

      expect(response).to have_http_status(:ok)
    end

    # This feature is free. If someone adds check_credits! later, this fails.
    it "never spends credits" do
      # Realize the lazy lets first: User#after_create makes an initial grant
      # transaction, which would otherwise land inside the expect block and
      # mask what we're actually measuring.
      profile

      expect {
        post_suggestions(field_key: "profile_about_me", subject_id: profile.id)
      }.not_to change(CreditTransaction, :count)
    end
  end
end
