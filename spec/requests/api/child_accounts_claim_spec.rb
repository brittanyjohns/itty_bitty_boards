# frozen_string_literal: true

require "rails_helper"

# Issue #160 (B4) — claim hand-off through the API.
RSpec.describe "API::ChildAccounts claim flow", type: :request do
  let(:slp) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:parent) do
    u = create(:user, created_at: 2.months.ago)
    u.setup_free_limits
    u.save!
    u
  end
  let!(:loaner) do
    account = create(:child_account, user: slp, owner: slp, status: "loaner", passcode: "loaner01")
    account.ensure_team!(creator: slp)
    account
  end

  describe "POST /api/child_accounts/:id/claim_link" do
    it "issues a claim link the SLP can share" do
      post "/api/child_accounts/#{loaner.id}/claim_link", headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["claim_token"]).to be_present
      expect(body["claim_url"]).to include(body["claim_token"])
    end

    it "rejects non-owners" do
      other = create(:user)
      post "/api/child_accounts/#{loaner.id}/claim_link", headers: auth_headers(other)
      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "GET /api/child_accounts/claim/:token (public preview)" do
    before { loaner.generate_claim_token! }

    it "returns minimal info without requiring auth" do
      get "/api/child_accounts/claim/#{loaner.claim_token}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["name"]).to eq(loaner.display_name)
      expect(body["owner_name"]).to eq(slp.display_name)
    end

    it "404s on an unknown token" do
      get "/api/child_accounts/claim/garbage"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/child_accounts/claim/:token" do
    before { loaner.generate_claim_token! }

    it "lets the parent claim, transferring ownership" do
      post "/api/child_accounts/claim/#{loaner.claim_token}", headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      loaner.reload
      expect(loaner.status).to eq("active")
      expect(loaner.owner_id).to eq(parent.id)
    end

    it "returns slot_full when the parent has no room" do
      create(:child_account, user: parent, owner: parent, status: "active",
                             passcode: "x", username: "preclaimed-#{SecureRandom.hex(2)}")

      post "/api/child_accounts/claim/#{loaner.claim_token}", headers: auth_headers(parent)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(JSON.parse(response.body)["error"]).to eq("slot_full")
      expect(loaner.reload.status).to eq("loaner")
    end
  end

  describe "POST /api/child_accounts/:id/end_loan" do
    it "lets the SLP reclaim the slot" do
      post "/api/child_accounts/#{loaner.id}/end_loan", headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      expect(loaner.reload.status).to eq("sandbox")
    end

    it "rejects non-owners" do
      other = create(:user)
      post "/api/child_accounts/#{loaner.id}/end_loan", headers: auth_headers(other)
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
