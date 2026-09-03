require "rails_helper"

# AAC personalization fields (aac_level / vocab_type / age_band) ride the
# existing wholesale `details` param on communicator update — same pattern as
# details["interests"]. Model-level validation rejects invalid values.
RSpec.describe "API::ChildAccounts AAC profile", type: :request do
  let(:user) { create(:user) }
  let(:communicator) { create(:child_account, user: user) }
  let(:headers) { auth_headers(user).merge("Content-Type" => "application/json") }

  describe "PATCH /api/child_accounts/:id" do
    it "persists valid profile fields via details and exposes them in the api_view" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { details: { aac_level: "emerging", vocab_type: "core", age_band: "4-6" } }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["aac_level"]).to eq("emerging")
      expect(body["vocab_type"]).to eq("core")
      expect(body["age_band"]).to eq("4-6")

      communicator.reload
      expect(communicator.aac_level).to eq("emerging")
      expect(communicator.details["age_band"]).to eq("4-6")
    end

    it "rejects an invalid aac_level with a validation error" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { details: { aac_level: "wizard" } }.to_json,
            headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(communicator.reload.aac_level).to be_nil
    end

    it "allows clearing a stored field" do
      communicator.update!(details: { "aac_level" => "emerging" })

      patch "/api/child_accounts/#{communicator.id}",
            params: { details: { aac_level: "" } }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(communicator.reload.aac_level).to be_nil
    end

    it "persists glp_stage as an integer and exposes it in the api_view" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { details: { glp_stage: 3, aac_level: "developing" } }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["glp_stage"]).to eq(3)
      expect(body["aac_level"]).to eq("developing")
      expect(communicator.reload.details["glp_stage"]).to eq(3)
    end

    it "rejects an out-of-range glp_stage" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { details: { glp_stage: 7 } }.to_json,
            headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(communicator.reload.glp_stage).to be_nil
    end

    it "clears glp_stage when sent blank" do
      communicator.update!(details: { "glp_stage" => 2 })

      patch "/api/child_accounts/#{communicator.id}",
            params: { details: { glp_stage: nil } }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(communicator.reload.glp_stage).to be_nil
    end
  end

  # Every other attribute this controller reads (name, username, status,
  # layout) is a top-level param, so a caller sending `{ age_band: "15-18" }`
  # reasonably expects it to land. It used to be a silent no-op.
  describe "top-level AAC profile params" do
    it "accepts them on update" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { age_band: "15-18", aac_level: "developing", vocab_type: "balanced", glp_stage: 4 }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      communicator.reload
      expect(communicator.age_band).to eq("15-18")
      expect(communicator.aac_level).to eq("developing")
      expect(communicator.vocab_type).to eq("balanced")
      expect(communicator.glp_stage).to eq(4)
    end

    it "accepts them on create" do
      post "/api/child_accounts",
           params: { name: "Jordan", status: "sandbox", age_band: "15-18" }.to_json,
           headers: headers

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["age_band"]).to eq("15-18")
    end

    it "still rejects an invalid value" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { age_band: "middle-aged" }.to_json,
            headers: headers

      expect(response).to have_http_status(:unprocessable_content)
      expect(communicator.reload.age_band).to be_nil
    end

    # `details` replaces wholesale; an explicit top-level field is the more
    # specific instruction and is applied after it.
    it "wins over the same key inside details" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { details: { age_band: "4-6" }, age_band: "adult" }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(communicator.reload.age_band).to eq("adult")
    end

    it "leaves a stored field alone when the key is absent" do
      communicator.update!(details: { "age_band" => "7-10" })

      patch "/api/child_accounts/#{communicator.id}",
            params: { name: "Jordan" }.to_json,
            headers: headers

      expect(response).to have_http_status(:ok)
      expect(communicator.reload.age_band).to eq("7-10")
    end
  end
end
