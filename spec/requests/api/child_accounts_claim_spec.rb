# frozen_string_literal: true

require "rails_helper"

# Issue #160 (B4) — claim hand-off through the API.
RSpec.describe "API::ChildAccounts claim flow", type: :request do
  include ActiveJob::TestHelper

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

    # This action used to call generate_claim_token! unconditionally, so an SLP
    # who emailed a claim link and then reopened the Lend panel silently killed
    # the link the family was holding.
    it "reuses an existing token instead of rotating it" do
      loaner.generate_claim_token!
      original = loaner.claim_token

      post "/api/child_accounts/#{loaner.id}/claim_link", headers: auth_headers(slp)

      expect(JSON.parse(response.body)["claim_token"]).to eq(original)
      expect(loaner.reload.claim_token).to eq(original)
    end

    it "rotates on an explicit rotate=true" do
      loaner.generate_claim_token!
      original = loaner.claim_token

      post "/api/child_accounts/#{loaner.id}/claim_link",
           params: { rotate: true }, headers: auth_headers(slp)

      expect(JSON.parse(response.body)["claim_token"]).not_to eq(original)
    end
  end

  # An email cannot be rewritten client-side the way the app UI rebuilds a
  # localhost claim_url, so a misconfigured FRONT_END_URL must refuse to send
  # rather than deliver a dead link to a family.
  describe "claim link host resolution" do
    # The guard only bites in production — in dev and test, localhost IS the
    # front end and sending is correct.
    it "refuses to email a claim link when the base URL is localhost in production" do
      allow(Rails.env).to receive(:production?).and_return(true)
      allow(ChildAccount).to receive(:front_end_base_url_sendable?).and_return(false)

      expect {
        post "/api/child_accounts/#{loaner.id}/send_claim_link",
             params: { email: "parent@example.com" }, headers: auth_headers(slp)
      }.not_to change { ActionMailer::Base.deliveries.size }

      expect(response).to have_http_status(:service_unavailable)
    end

    it "still sends outside production, where localhost is the real front end" do
      allow(ChildAccount).to receive(:front_end_base_url_sendable?).and_return(false)

      post "/api/child_accounts/#{loaner.id}/send_claim_link",
           params: { email: "parent@example.com" }, headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
    end

    it "falls back to the production host when FRONT_END_URL is unset in production" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("FRONT_END_URL").and_return(nil)
      allow(Rails.env).to receive(:production?).and_return(true)

      expect(ChildAccount.front_end_base_url).to eq(ChildAccount::PRODUCTION_FRONT_END_URL)
      expect(ChildAccount.front_end_base_url_sendable?).to be(true)
    end

    it "treats a localhost base as unsendable" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("FRONT_END_URL").and_return("http://localhost:8100")

      expect(ChildAccount.front_end_base_url_sendable?).to be(false)
    end
  end

  describe "GET /api/communicator_claims/:token (public preview)" do
    before { loaner.generate_claim_token! }

    it "returns the preview shape without requiring auth" do
      get "/api/communicator_claims/#{loaner.claim_token}"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["child_name"]).to eq(loaner.display_name)
      expect(body["communicator_name"]).to eq(loaner.display_name)
      expect(body["owner_name"]).to eq(slp.display_name)
      expect(body["owner_email"]).to eq(slp.email)
      expect(body["status"]).to eq("loaner")
      expect(body["expired"]).to be(false)
      expect(body["already_claimed"]).to be(false)
    end

    it "reports already_claimed once the loaner has been claimed" do
      loaner.claim_by!(user: parent)
      get "/api/communicator_claims/#{loaner.claim_token}"
      # claim clears the token, so this 404s — caller should have a
      # token from BEFORE the claim. Simulate by re-issuing one on the
      # now-active account (the preview just inspects the row).
      loaner.update_column(:claim_token, "preview-token")

      get "/api/communicator_claims/preview-token"
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["status"]).to eq("claimed")
      expect(body["already_claimed"]).to be(true)
    end

    it "404s on an unknown token" do
      get "/api/communicator_claims/garbage"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /api/communicator_claims/:token/claim" do
    before { loaner.generate_claim_token! }

    it "lets the parent claim, transferring ownership" do
      post "/api/communicator_claims/#{loaner.claim_token}/claim", headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["account"]).to be_present
      expect(body["account"]["status"]).to eq("active")
      expect(loaner.reload.owner_id).to eq(parent.id)
    end

    it "returns slot_full when the parent has no room" do
      create(:child_account, user: parent, owner: parent, status: "active",
                             passcode: "x", username: "preclaimed-#{SecureRandom.hex(2)}")

      post "/api/communicator_claims/#{loaner.claim_token}/claim", headers: auth_headers(parent)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("slot_full")
      expect(loaner.reload.status).to eq("loaner")
    end
  end

  describe "POST /api/child_accounts/:id/lend" do
    let!(:sandbox) do
      account = create(:child_account, user: slp, owner: slp, status: "sandbox", passcode: nil)
      account.ensure_team!(creator: slp)
      account
    end

    it "promotes sandbox → loaner and returns a claim_url in one round trip" do
      post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(slp)

      expect(response).to have_http_status(:ok)
      sandbox.reload
      expect(sandbox.status).to eq("loaner")
      expect(sandbox.claim_token).to be_present
      body = JSON.parse(response.body)
      expect(body["claim_url"]).to include(sandbox.claim_token)
      expect(body["loaned_at"]).to be_present
    end

    it "rotates the token when called again on a loaner" do
      sandbox.promote_to_loaner!(passcode: "abc")
      old_token = sandbox.generate_claim_token!

      post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(slp)
      expect(response).to have_http_status(:ok)
      expect(sandbox.reload.claim_token).not_to eq(old_token)
    end

    # Issue #164 — an SLP can lend an active they self-created. The
    # ownership guard is sufficient: by the time we get here, the
    # caller IS the owner, which means no family ever claimed it.
    context "when the SLP owns an active communicator (issue #164)" do
      let!(:slp_active) do
        account = create(:child_account, user: slp, owner: slp, status: "active",
                                         passcode: "knownpass", username: "slp-active-#{SecureRandom.hex(2)}")
        account.ensure_team!(creator: slp)
        account
      end

      it "promotes active → loaner and rotates the passcode" do
        post "/api/child_accounts/#{slp_active.id}/lend", headers: auth_headers(slp)

        expect(response).to have_http_status(:ok)
        slp_active.reload
        expect(slp_active.status).to eq("loaner")
        expect(slp_active.passcode).not_to eq("knownpass")
        expect(slp_active.passcode).to be_present
        expect(slp_active.claim_token).to be_present
      end

      it "honors a caller-supplied passcode override" do
        post "/api/child_accounts/#{slp_active.id}/lend",
          params: { passcode: "handoff42" },
          headers: auth_headers(slp)

        expect(response).to have_http_status(:ok)
        expect(slp_active.reload.passcode).to eq("handoff42")
      end

      it "rejects with the family-claimed message when the caller doesn't own the active" do
        slp_active.update!(owner: parent, user: parent, claimed_at: Time.current)

        post "/api/child_accounts/#{slp_active.id}/lend", headers: auth_headers(slp)

        expect(response).to have_http_status(:unprocessable_content)
        expect(JSON.parse(response.body)["error"]).to match(/owned by someone else/i)
        expect(slp_active.reload.status).to eq("active")
      end
    end
  end

  describe "POST /api/child_accounts/:id/send_claim_link" do
    before do
      loaner.generate_claim_token!
      ActionMailer::Base.deliveries.clear
    end

    it "delivers the claim link to the supplied email" do
      perform_enqueued_jobs do
        post "/api/child_accounts/#{loaner.id}/send_claim_link",
          params: { email: "family@example.com" },
          headers: auth_headers(slp)
      end

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["ok"]).to be(true)
      expect(body["claim_url"]).to include(loaner.reload.claim_token)
      expect(ActionMailer::Base.deliveries.last.to).to eq(["family@example.com"])
    end

    it "rejects a bad email" do
      post "/api/child_accounts/#{loaner.id}/send_claim_link",
        params: { email: "not-an-email" },
        headers: auth_headers(slp)
      expect(response).to have_http_status(:unprocessable_content)
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
