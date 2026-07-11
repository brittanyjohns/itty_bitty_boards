# frozen_string_literal: true

require "rails_helper"

# Issues #210 / #211 — owner-protection on the content-mutating
# communicator endpoints. After the SLP→parent claim hand-off, the SLP
# stays on the team as a supervisor (board-sharer only). Direct edits
# to the communicator object — name/passcode/voice/settings/layout, the
# boards roster, and the setup email — must be owner-only. Mirrors the
# shape of spec/requests/api/team_permissions_spec.rb.
RSpec.describe "API::ChildAccounts owner protection", type: :request do
  let(:slp)    { create(:user, plan_type: "pro", created_at: 2.months.ago, stripe_customer_id: "cus_slp_stub") }
  let(:parent) { create(:user, created_at: 2.months.ago, stripe_customer_id: "cus_parent_stub") }
  let(:admin)  { create(:admin_user) }

  # Mirror the post-claim shape: the parent is the owner, the SLP is on
  # the team as a supervisor.
  let!(:account) do
    create(:child_account,
           user: parent,
           owner: parent,
           status: ChildAccount::ACTIVE,
           passcode: "ownerpw1")
  end
  let!(:team) do
    t = account.ensure_team!(creator: slp)
    t.upsert_member!(parent, "admin")
    t.upsert_member!(slp, "supervisor")
    t
  end

  describe "PATCH /api/child_accounts/:id" do
    let(:rename_params) { { name: "New Name" } }

    it "lets the parent owner rename the communicator" do
      patch "/api/child_accounts/#{account.id}",
            params: rename_params,
            headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      expect(account.reload.name).to eq("New Name")
    end

    it "blocks an SLP supervisor (403 not_authorized)" do
      patch "/api/child_accounts/#{account.id}",
            params: rename_params,
            headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
      expect(account.reload.name).not_to eq("New Name")
    end

    it "lets a system admin through (escape hatch)" do
      patch "/api/child_accounts/#{account.id}",
            params: rename_params,
            headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(account.reload.name).to eq("New Name")
    end
  end

  describe "POST /api/child_accounts/:id/assign_boards" do
    let!(:board) { Board.create!(user: parent, name: "Shared Board", number_of_columns: 3) }

    it "lets the parent owner assign a board" do
      expect {
        post "/api/child_accounts/#{account.id}/assign_boards",
             params: { board_ids: [board.id] },
             headers: auth_headers(parent)
      }.to change { account.reload.child_boards.count }.by(1)

      expect(response).to have_http_status(:ok)
    end

    # Phase 1 (team permissions overhaul): assigning boards to the dashboard
    # is a curation action, so a team supervisor may now do it — this used to
    # be owner-only. Editing the communicator object itself stays owner-only
    # (covered above and in send_setup_email below).
    it "lets an SLP supervisor assign a board" do
      expect {
        post "/api/child_accounts/#{account.id}/assign_boards",
             params: { board_ids: [board.id] },
             headers: auth_headers(slp)
      }.to change { account.reload.child_boards.count }.by(1)

      expect(response).to have_http_status(:ok)
    end

    it "lets a system admin through (escape hatch)" do
      expect {
        post "/api/child_accounts/#{account.id}/assign_boards",
             params: { board_ids: [board.id] },
             headers: auth_headers(admin)
      }.to change { account.reload.child_boards.count }.by(1)

      expect(response).to have_http_status(:ok)
    end
  end

  # Sandbox accounts are capped server-side (settings["demo_board_limit"],
  # default ChildAccount::DEMO_ACCOUNT_BOARD_LIMIT). The cap must count
  # *boards*, not the characters of a scalar id — board_ids can arrive as a
  # single value rather than an array, and an earlier version measured its
  # `.size` before normalizing, so "42" counted as 2 boards.
  describe "POST /api/child_accounts/:id/assign_boards (sandbox limit)" do
    let!(:sandbox) do
      create(:child_account,
             user: parent,
             owner: parent,
             status: ChildAccount::SANDBOX,
             settings: { "demo_board_limit" => 1 })
    end
    # Multi-digit id so a `.size`-on-string regression (2) differs from the
    # real count (1) and would trip the cap incorrectly.
    let!(:public_board) { Board.create!(id: 90_001, user: slp, name: "Public Board", number_of_columns: 3, predefined: true) }

    it "counts a single (scalar) board id as one board against the cap" do
      expect {
        post "/api/child_accounts/#{sandbox.id}/assign_boards",
             params: { board_ids: public_board.id },
             headers: auth_headers(parent)
      }.to change { sandbox.reload.child_boards.count }.by(1)

      expect(response).to have_http_status(:ok)
    end

    it "rejects with 422 once the sandbox is over its board limit" do
      sandbox.update!(settings: { "demo_board_limit" => 0 })

      expect {
        post "/api/child_accounts/#{sandbox.id}/assign_boards",
             params: { board_ids: [public_board.id] },
             headers: auth_headers(parent)
      }.not_to change { sandbox.reload.child_boards.count }

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to match(/Demo board limit exceeded/)
    end

    it "returns 422 when no board_ids are provided" do
      post "/api/child_accounts/#{sandbox.id}/assign_boards",
           headers: auth_headers(parent)

      expect(response).to have_http_status(:unprocessable_content)
      expect(JSON.parse(response.body)["error"]).to eq("No board_ids provided")
    end
  end

  describe "POST /api/child_accounts/:id/send_setup_email" do
    before do
      mailer = double("CommunicationAccountMailer", deliver_later: true)
      allow(CommunicationAccountMailer).to receive(:setup_email).and_return(mailer)
    end

    it "lets the parent owner send the setup email" do
      post "/api/child_accounts/#{account.id}/send_setup_email",
           headers: auth_headers(parent)

      expect(response).to have_http_status(:ok)
      expect(CommunicationAccountMailer).to have_received(:setup_email).with(account, parent)
    end

    it "blocks an SLP supervisor (403 not_authorized)" do
      post "/api/child_accounts/#{account.id}/send_setup_email",
           headers: auth_headers(slp)

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
      expect(CommunicationAccountMailer).not_to have_received(:setup_email)
    end

    it "lets a system admin through (escape hatch)" do
      post "/api/child_accounts/#{account.id}/send_setup_email",
           headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(CommunicationAccountMailer).to have_received(:setup_email).with(account, admin)
    end
  end
end
