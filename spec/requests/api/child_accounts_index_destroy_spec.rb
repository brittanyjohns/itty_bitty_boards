# frozen_string_literal: true

require "rails_helper"

# Hardening: the roster index scopes on owner_id (matching the "X of Y" slot
# counts), and destroy blocks a lent-out communicator so a live claim link is
# never orphaned mid-hand-off.
RSpec.describe "API::ChildAccounts index + destroy", type: :request do
  let(:owner) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

  describe "GET /api/child_accounts" do
    it "returns the caller's owned communicators, including a lent-out loaner" do
      active = create(:child_account, owner: owner, user: owner, status: "active",
                                      username: "ac-#{SecureRandom.hex(2)}")
      loaner = create(:child_account, owner: owner, user: owner, status: "loaner",
                                      username: "ln-#{SecureRandom.hex(2)}")

      get "/api/child_accounts", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      ids = JSON.parse(response.body).map { |a| a["id"] }
      expect(ids).to contain_exactly(active.id, loaner.id)
    end

    it "excludes a communicator owned by someone else (scoped on owner_id)" do
      other = create(:user, plan_type: "pro", created_at: 2.months.ago)
      mine = create(:child_account, owner: owner, user: owner, status: "active",
                                    username: "mine-#{SecureRandom.hex(2)}")
      # A row whose legacy user_id points at the caller but whose canonical
      # owner is someone else must NOT appear — this is the divergence the
      # owner_id scope fixes.
      create(:child_account, owner: other, user: owner, status: "active",
                             username: "theirs-#{SecureRandom.hex(2)}")

      get "/api/child_accounts", headers: auth_headers(owner)

      ids = JSON.parse(response.body).map { |a| a["id"] }
      expect(ids).to eq([mine.id])
    end
  end

  describe "GET /api/child_accounts?handed_off=true" do
    # Simulate the post-hand-off state: a family now owns the communicator and
    # the original SLP (the caller) remains on its team as a supervisor.
    let(:family) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

    def handed_off_communicator(supervisor:, claimed: true)
      account = create(:child_account, owner: family, user: family, status: "active",
                                       claimed_at: (claimed ? Time.current : nil),
                                       username: "ho-#{SecureRandom.hex(3)}")
      team = create(:team, created_by: family)
      TeamAccount.create!(team: team, account: account)
      TeamUser.create!(team: team, user: family, role: "admin")
      TeamUser.create!(team: team, user: supervisor, role: "supervisor")
      account
    end

    it "lists claimed communicators the caller supervises but no longer owns" do
      handed = handed_off_communicator(supervisor: owner)
      # A communicator the caller still owns must not appear in this view.
      create(:child_account, owner: owner, user: owner, status: "active",
                             username: "own-#{SecureRandom.hex(2)}")

      get "/api/child_accounts?handed_off=true", headers: auth_headers(owner)

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body.map { |a| a["id"] }).to eq([handed.id])
      expect(body.first["parent_name"]).to eq(family.display_name)
      expect(body.first["claimed_at"]).to be_present
    end

    it "excludes a supervised communicator that was never claimed" do
      handed_off_communicator(supervisor: owner, claimed: false)

      get "/api/child_accounts?handed_off=true", headers: auth_headers(owner)

      expect(JSON.parse(response.body)).to be_empty
    end

    it "does not leak communicators the caller doesn't supervise" do
      stranger = create(:user, plan_type: "pro", created_at: 2.months.ago)
      handed_off_communicator(supervisor: stranger)

      get "/api/child_accounts?handed_off=true", headers: auth_headers(owner)

      expect(JSON.parse(response.body)).to be_empty
    end
  end

  describe "DELETE /api/child_accounts/:id" do
    it "lets the owner delete a sandbox communicator" do
      sandbox = create(:child_account, owner: owner, user: owner, status: "sandbox",
                                       username: "sb-#{SecureRandom.hex(2)}")

      delete "/api/child_accounts/#{sandbox.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:no_content).or have_http_status(:ok)
      expect(ChildAccount.exists?(sandbox.id)).to be(false)
    end

    it "blocks deleting a lent-out loaner with end_loan guidance" do
      loaner = create(:child_account, owner: owner, user: owner, status: "loaner",
                                      username: "ln-#{SecureRandom.hex(2)}")

      delete "/api/child_accounts/#{loaner.id}", headers: auth_headers(owner)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to match(/end_loan/i)
      expect(ChildAccount.exists?(loaner.id)).to be(true)
    end

    it "rejects a non-owner" do
      other = create(:user)
      sandbox = create(:child_account, owner: owner, user: owner, status: "sandbox",
                                       username: "sb-#{SecureRandom.hex(2)}")

      delete "/api/child_accounts/#{sandbox.id}", headers: auth_headers(other)

      expect(response).to have_http_status(:unauthorized)
      expect(ChildAccount.exists?(sandbox.id)).to be(true)
    end
  end
end
