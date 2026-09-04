require "rails_helper"

# Served so both age selects stop carrying their own copy of the band list.
# The assertions are about the payload matching the constant exactly, not about
# it matching a fixture of what the constant happened to say — a drifted copy
# is the whole failure this endpoint exists to end.
RSpec.describe "API::AgeBands", type: :request do
  describe "GET /api/age_bands" do
    it "is readable without a token" do
      get "/api/age_bands"
      expect(response).to have_http_status(:ok)
    end

    it "serves every band in order, with a label" do
      get "/api/age_bands"
      body = JSON.parse(response.body)

      expect(body["age_bands"].map { |b| b["value"] }).to eq(CommunicatorProfile::AGE_BANDS)
      expect(body["age_bands"].map { |b| b["label"] }).to all(be_present)
    end

    # Every value it publishes has to be one ChildAccount will accept, or the
    # form offers a choice the save rejects.
    it "publishes only values a communicator can actually be saved with" do
      get "/api/age_bands"
      body = JSON.parse(response.body)

      body["age_bands"].each do |band|
        account = build(:child_account, details: { "age_band" => band["value"] })
        account.validate
        expect(account.errors[:age_band]).to be_empty
      end
    end

    it "falls back to the default locale for an unknown one rather than reaching I18n with it" do
      get "/api/age_bands", params: { locale: "../../etc" }
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["age_bands"].first["label"]).to be_present
    end
  end
end
