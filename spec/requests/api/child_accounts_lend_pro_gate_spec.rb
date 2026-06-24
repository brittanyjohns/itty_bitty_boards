# frozen_string_literal: true

require "rails_helper"

# Lending / hand-off is a Pro-only feature. The gate must hold server-side,
# not only in the frontend LoanerControls. See
# API::ChildAccountsController#require_pro_for_lending!.
RSpec.describe "API::ChildAccounts lending Pro gate", type: :request do
  def sandbox_owned_by(owner)
    create(:child_account, user: owner, owner: owner, status: "sandbox", passcode: nil)
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
  end
end
