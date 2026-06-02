# frozen_string_literal: true

require "rails_helper"

# Issue #165 — archive/unarchive endpoints for sandbox communicators.
RSpec.describe "API::ChildAccounts archive", type: :request do
  let(:user) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let!(:sandbox) { create(:child_account, user: user, owner: user, status: "sandbox") }

  describe "POST /api/child_accounts/:id/archive" do
    it "archives a sandbox and drops it from the default communicator list" do
      post "/api/child_accounts/#{sandbox.id}/archive", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["archived_at"]).to be_present

      get "/api/child_accounts", headers: auth_headers(user)
      ids = JSON.parse(response.body).map { |a| a["id"] }
      expect(ids).not_to include(sandbox.id)
    end

    it "rejects non-owners" do
      other = create(:user)
      post "/api/child_accounts/#{sandbox.id}/archive", headers: auth_headers(other)
      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses on loaner" do
      loaner = create(:child_account, user: user, owner: user, status: "loaner", username: "ln-#{SecureRandom.hex(2)}")
      post "/api/child_accounts/#{loaner.id}/archive", headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "refuses on active" do
      active = create(:child_account, user: user, owner: user, status: "active", username: "ac-#{SecureRandom.hex(2)}")
      post "/api/child_accounts/#{active.id}/archive", headers: auth_headers(user)
      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe "POST /api/child_accounts/:id/unarchive" do
    before { sandbox.archive! }

    it "restores an archived sandbox" do
      post "/api/child_accounts/#{sandbox.id}/unarchive", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["archived_at"]).to be_nil

      get "/api/child_accounts", headers: auth_headers(user)
      ids = JSON.parse(response.body).map { |a| a["id"] }
      expect(ids).to include(sandbox.id)
    end
  end

  describe "GET /api/child_accounts?archived=true" do
    let!(:active) { create(:child_account, user: user, owner: user, status: "active", username: "ac-#{SecureRandom.hex(2)}") }
    let!(:archived_sandbox) do
      sb = create(:child_account, user: user, owner: user, status: "sandbox", username: "sb-#{SecureRandom.hex(2)}")
      sb.archive!
      sb
    end

    it "returns only the caller's archived records" do
      get "/api/child_accounts?archived=true", headers: auth_headers(user)

      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).map { |a| a["id"] }
      expect(ids).to include(archived_sandbox.id)
      expect(ids).not_to include(sandbox.id, active.id)
    end

    it "does not leak other users' archived records" do
      other = create(:user)
      other_sandbox = create(:child_account, user: other, owner: other, status: "sandbox", username: "ot-#{SecureRandom.hex(2)}")
      other_sandbox.archive!

      get "/api/child_accounts?archived=true", headers: auth_headers(user)

      ids = JSON.parse(response.body).map { |a| a["id"] }
      expect(ids).not_to include(other_sandbox.id)
    end

    it "default list still excludes archived records" do
      get "/api/child_accounts", headers: auth_headers(user)

      ids = JSON.parse(response.body).map { |a| a["id"] }
      expect(ids).to include(sandbox.id, active.id)
      expect(ids).not_to include(archived_sandbox.id)
    end
  end
end
