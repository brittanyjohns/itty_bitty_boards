# frozen_string_literal: true

require "rails_helper"

# Phase 1 — supervisors (and account owners / sysadmins) may assign boards
# to a communicator's dashboard, while editing the communicator object stays
# owner-only. Auth failures use the structured { error, message } body with
# 403. See .claude-notes/team-permissions-overhaul-handoff.md.
RSpec.describe "API::ChildAccounts#assign_boards permissions", type: :request do
  let(:owner)      { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:supervisor) { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:member)     { create(:user, created_at: 2.months.ago) }
  let(:restricted) { create(:user, created_at: 2.months.ago) }
  let(:stranger)   { create(:user, created_at: 2.months.ago) }
  let(:sysadmin)   { create(:admin_user) }

  let!(:communicator) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE)
  end

  let!(:team) do
    t = Team.create!(name: "Care Team", created_by: owner)
    TeamAccount.create!(team: t, account: communicator)
    t.upsert_member!(owner, "admin")
    t.upsert_member!(supervisor, "supervisor")
    t.upsert_member!(member, "member")
    t.upsert_member!(restricted, "restricted")
    t
  end

  let!(:board) { create(:board, user: owner, name: "Snack Time") }

  def assign!(user)
    post "/api/child_accounts/#{communicator.id}/assign_boards",
         params: { board_ids: [board.id] },
         headers: auth_headers(user)
  end

  it "lets the account owner assign boards" do
    assign!(owner)
    expect(response).to have_http_status(:ok)
  end

  it "lets a team supervisor assign boards to the dashboard" do
    expect { assign!(supervisor) }.to change { communicator.reload.child_boards.count }.by(1)
    expect(response).to have_http_status(:ok)
  end

  it "lets a system admin assign boards" do
    assign!(sysadmin)
    expect(response).to have_http_status(:ok)
  end

  it "blocks a plain member (Support role) with 403 and the structured body" do
    expect { assign!(member) }.not_to change { communicator.reload.child_boards.count }
    expect(response).to have_http_status(:forbidden)
    body = JSON.parse(response.body)
    expect(body["error"]).to eq("not_authorized")
    expect(body["message"]).to eq(
      "Only the account owner or a team supervisor can add boards to this dashboard.",
    )
  end

  it "blocks a restricted (Read-Only) member (403)" do
    expect { assign!(restricted) }.not_to change { communicator.reload.child_boards.count }
    expect(response).to have_http_status(:forbidden)
    expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
  end

  it "blocks a stranger who isn't on the team (403)" do
    expect { assign!(stranger) }.not_to change { communicator.reload.child_boards.count }
    expect(response).to have_http_status(:forbidden)
  end

  describe "decision 3 — plan is not gated on the supervisor" do
    it "lets a FREE (unpaid) supervisor assign boards" do
      free_supervisor = create(:user, plan_type: "free", created_at: 1.year.ago)
      team.upsert_member!(free_supervisor, "supervisor")

      assign!(free_supervisor)
      expect(response).to have_http_status(:ok)
    end

    it "lets a CANCELLED-plan supervisor assign boards" do
      cancelled_supervisor = create(:user, plan_type: "pro", plan_status: "canceled",
                                           created_at: 1.year.ago)
      expect(cancelled_supervisor.paid_plan?).to be(false)
      team.upsert_member!(cancelled_supervisor, "supervisor")

      assign!(cancelled_supervisor)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "editing the communicator object stays owner-only" do
    it "blocks a supervisor from renaming the communicator (403 not_authorized)" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { child_account: { name: "Renamed" } },
            headers: auth_headers(supervisor)
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
    end

    it "lets the owner rename the communicator" do
      patch "/api/child_accounts/#{communicator.id}",
            params: { child_account: { name: "Renamed" } },
            headers: auth_headers(owner)
      expect(response).to have_http_status(:ok)
    end
  end
end
