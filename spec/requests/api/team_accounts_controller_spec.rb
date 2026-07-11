# frozen_string_literal: true

require "rails_helper"

# Phase 0 — attaching a communicator to a team is locked down: the caller
# must OWN the communicator and MANAGE the target team (or be a sysadmin).
# Reassigning team_id/child_account_id via update is disallowed. See
# .claude-notes/team-permissions-overhaul-handoff.md.
RSpec.describe "API::TeamAccounts permissions", type: :request do
  let(:owner)    { create(:user, plan_type: "pro", created_at: 2.months.ago) }
  let(:sysadmin) { create(:admin_user) }

  let!(:communicator) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE)
  end

  # Team created (and thus managed) by owner, who also owns the communicator.
  let!(:team) do
    t = Team.create!(name: "Care Team", created_by: owner)
    t.upsert_member!(owner, "admin")
    t
  end

  def attach(user, team_id: team.id, account_id: communicator.id)
    post "/api/team_accounts",
         params: { team_id: team_id, account_id: account_id },
         headers: auth_headers(user)
  end

  describe "POST /api/team_accounts (create)" do
    it "lets the team owner attach a communicator they own (201)" do
      expect { attach(owner) }.to change { TeamAccount.count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "lets a system admin attach any communicator to any team (201)" do
      expect { attach(sysadmin) }.to change { TeamAccount.count }.by(1)
      expect(response).to have_http_status(:created)
    end

    it "blocks a user who owns the communicator but does not manage the team (403)" do
      outsider = create(:user, created_at: 2.months.ago)
      outsider_comm = create(:child_account, user: outsider, owner: outsider,
                                             status: ChildAccount::ACTIVE)
      expect {
        attach(outsider, account_id: outsider_comm.id)
      }.not_to change { TeamAccount.count }
      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["error"]).to eq("not_authorized")
    end

    it "blocks a team manager who does NOT own the communicator (403)" do
      # A second admin-role member of the team, but the communicator isn't theirs.
      manager = create(:user, created_at: 2.months.ago)
      team.upsert_member!(manager, "admin")
      expect { attach(manager) }.not_to change { TeamAccount.count }
      expect(response).to have_http_status(:forbidden)
    end

    it "blocks a supervisor (non-manager role) even if on the team (403)" do
      supervisor = create(:user, created_at: 2.months.ago)
      team.upsert_member!(supervisor, "supervisor")
      supervisor_comm = create(:child_account, user: supervisor, owner: supervisor,
                                               status: ChildAccount::ACTIVE)
      expect {
        attach(supervisor, account_id: supervisor_comm.id)
      }.not_to change { TeamAccount.count }
      expect(response).to have_http_status(:forbidden)
    end

    it "blocks a stranger who isn't on the team (403)" do
      stranger = create(:user, created_at: 2.months.ago)
      expect { attach(stranger) }.not_to change { TeamAccount.count }
      expect(response).to have_http_status(:forbidden)
    end
  end

  describe "PATCH /api/team_accounts/:id (update)" do
    let!(:team_account) { TeamAccount.create!(team: team, account: communicator) }

    it "does not allow reassigning team_id or child_account_id" do
      other_team = Team.create!(name: "Other", created_by: owner)
      other_comm = create(:child_account, user: owner, owner: owner,
                                          status: ChildAccount::ACTIVE)

      patch "/api/team_accounts/#{team_account.id}",
            params: { team_account: { team_id: other_team.id,
                                      child_account_id: other_comm.id } },
            headers: auth_headers(owner)

      team_account.reload
      expect(team_account.team_id).to eq(team.id)
      expect(team_account.child_account_id).to eq(communicator.id)
    end
  end
end
