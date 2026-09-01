# frozen_string_literal: true

require "rails_helper"

# Lending / hand-off is a paid, plan-gated feature. The gate must hold
# server-side, not only in the frontend LoanerControls. See
# API::ChildAccountsController#require_pro_for_lending! and User#can_lend?.
RSpec.describe "API::ChildAccounts lending Pro gate", type: :request do
  def sandbox_owned_by(owner)
    create(:child_account, user: owner, owner: owner, status: "sandbox", passcode: nil)
  end

  def clinician_owner
    owner = create(:user, plan_type: "clinician", created_at: 2.months.ago)
    owner.setup_clinician_limits
    owner.save!
    owner
  end

  describe "POST /lend" do
    it "rejects a Basic owner with 403 pro_required and leaves the status unchanged" do
      owner = create(:user, plan_type: "basic", created_at: 2.months.ago)
      sandbox = sandbox_owned_by(owner)

      post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(owner)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("pro_required")
      expect(sandbox.reload.status).to eq("sandbox")
    end

    it "rejects a Free owner with 403" do
      owner = create(:user, plan_type: "free", created_at: 2.months.ago)
      sandbox = sandbox_owned_by(owner)

      post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(owner)

      expect(response).to have_http_status(:forbidden)
    end

    it "allows a Pro owner to lend (sandbox -> loaner)" do
      owner = create(:user, plan_type: "pro", created_at: 2.months.ago)
      owner.setup_pro_limits
      owner.save!
      sandbox = sandbox_owned_by(owner)

      post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(sandbox.reload.status).to eq("loaner")
    end

    it "blocks a Basic owner from lending a self-created active (active -> loaner path)" do
      owner = create(:user, plan_type: "basic", created_at: 2.months.ago)
      active = create(:child_account, user: owner, owner: owner, status: "active",
                                      passcode: "x", username: "act-#{SecureRandom.hex(2)}")

      post "/api/child_accounts/#{active.id}/lend", headers: auth_headers(owner)

      expect(response).to have_http_status(:forbidden)
      expect(active.reload.status).to eq("active")
    end

    # #820 — the Clinician plan advertises 2 loaner slots and the whole
    # clinician workflow is lend -> family claims -> slot recycles, but the gate
    # read `pro?` and clinician is deliberately not Pro, so every lend 403'd.
    it "allows a Clinician owner to lend (sandbox -> loaner)" do
      owner = clinician_owner
      sandbox = sandbox_owned_by(owner)

      post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(sandbox.reload.status).to eq("loaner")
      expect(JSON.parse(response.body)["claim_url"]).to be_present
    end

    it "still enforces the Clinician slot limit — the gate opens, the math does not" do
      owner = clinician_owner
      # CLINICIAN_PLAN_LIMITS is 2 paid slots; fill both.
      2.times do |i|
        create(:child_account, user: owner, owner: owner, status: "active",
                               passcode: "x", username: "clin-#{i}-#{SecureRandom.hex(2)}")
      end
      sandbox = sandbox_owned_by(owner)

      post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(owner)

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["error"]).to eq("Maximum number of communicator accounts reached.")
      expect(body["error_code"]).to eq("communicator_limit_reached")
      expect(body["limit"]).to eq(2)
      expect(body["count"]).to eq(2)
      expect(sandbox.reload.status).to eq("sandbox")
    end

    it "returns Unauthorized (not the Pro gate) for a non-owner, so the gate isn't leaked" do
      owner = create(:user, plan_type: "pro", created_at: 2.months.ago)
      sandbox = sandbox_owned_by(owner)
      other = create(:user, plan_type: "basic")

      post "/api/child_accounts/#{sandbox.id}/lend", headers: auth_headers(other)

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe "POST /promote_to_loaner" do
    it "rejects a Basic owner with 403 pro_required" do
      owner = create(:user, plan_type: "basic", created_at: 2.months.ago)
      sandbox = sandbox_owned_by(owner)

      post "/api/child_accounts/#{sandbox.id}/promote_to_loaner", headers: auth_headers(owner)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("pro_required")
      expect(sandbox.reload.status).to eq("sandbox")
    end

    it "allows a Clinician owner to promote a sandbox to a loaner" do
      owner = clinician_owner
      sandbox = sandbox_owned_by(owner)

      post "/api/child_accounts/#{sandbox.id}/promote_to_loaner", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      expect(sandbox.reload.status).to eq("loaner")
    end
  end

  describe "User#can_lend?" do
    it "is true for Pro and Clinician, false for Free and Basic" do
      expect(build(:user, plan_type: "pro").can_lend?).to be(true)
      expect(build(:user, plan_type: "partner_pro").can_lend?).to be(true)
      expect(build(:user, plan_type: "clinician").can_lend?).to be(true)
      expect(build(:user, plan_type: "basic").can_lend?).to be(false)
      expect(build(:user, plan_type: "free").can_lend?).to be(false)
    end

    # Clinician must NOT become Pro: its smaller slot cap is the product.
    it "does not fold Clinician into pro?" do
      expect(build(:user, plan_type: "clinician").pro?).to be(false)
    end
  end
end
