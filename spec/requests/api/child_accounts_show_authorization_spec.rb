# frozen_string_literal: true

require "rails_helper"

# Read authorization on GET /api/child_accounts/:id (#show).
#
# The communicator record carries its login passcode, account claim token,
# and safety/medical fields. `show` must admit only the owner, an admin, or a
# member of a team the communicator is on — never an arbitrary signed-in user
# — and must not hand the login/claim credentials to a non-owner even when a
# legitimate team relationship exists.
RSpec.describe "API::ChildAccounts#show authorization", type: :request do
  let(:parent)   { create(:user, created_at: 2.months.ago, stripe_customer_id: "cus_parent_stub") }
  let(:slp)      { create(:user, plan_type: "pro", created_at: 2.months.ago, stripe_customer_id: "cus_slp_stub") }
  let(:stranger) { create(:user, created_at: 2.months.ago, stripe_customer_id: "cus_stranger_stub") }
  let(:admin)    { create(:admin_user) }

  let!(:account) do
    create(:child_account,
           user: parent,
           owner: parent,
           status: ChildAccount::ACTIVE,
           passcode: "ownerpw1")
  end

  # Post-claim shape: parent owns, SLP is on the team as a supervisor.
  let!(:team) do
    t = account.ensure_team!(creator: slp)
    t.upsert_member!(parent, "admin")
    t.upsert_member!(slp, "supervisor")
    t
  end

  describe "who may read the communicator" do
    it "returns the full record (incl. passcode) to the owner" do
      get "/api/child_accounts/#{account.id}", headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["id"]).to eq(account.id)
      expect(body["passcode"]).to eq("ownerpw1")
      expect(body["is_owner"]).to be(true)
    end

    it "returns the record to a system admin" do
      get "/api/child_accounts/#{account.id}", headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["passcode"]).to eq("ownerpw1")
    end

    it "lets a team member view the record but withholds the passcode/claim credentials" do
      get "/api/child_accounts/#{account.id}", headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["id"]).to eq(account.id)          # a supervisor is a legitimate viewer
      expect(body["is_owner"]).to be(false)
      expect(body["passcode"]).to be_nil            # but never the login secret
      expect(body["claim_token"]).to be_nil
      expect(body["claim_url"]).to be_nil
    end

    it "returns a generic 404 to an unrelated signed-in user and leaks nothing" do
      get "/api/child_accounts/#{account.id}", headers: auth_headers(stranger)

      expect(response).to have_http_status(:not_found)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Communicator not found")
      expect(body).not_to have_key("passcode")
      expect(body).not_to have_key("username")
      expect(body).not_to have_key("claim_token")
    end

    it "requires authentication" do
      get "/api/child_accounts/#{account.id}"
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
