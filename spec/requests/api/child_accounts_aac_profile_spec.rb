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

      expect(response).to have_http_status(:unprocessable_entity)
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
  end
end
