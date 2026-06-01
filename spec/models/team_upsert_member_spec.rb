# frozen_string_literal: true

require "rails_helper"

# Issue #226 — `Team#upsert_member!` replaced the old `add_member!`.
# Behavior: add the membership if missing, update the role if the
# user is already on the team, raise on validation failure.
RSpec.describe Team, "#upsert_member!", type: :model do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) { create(:child_account, user: owner, owner: owner) }
  let(:team) { account.ensure_team!(creator: owner) }
  let(:user) { create(:user, created_at: 2.months.ago) }

  it "creates a new team_user with the given role" do
    expect {
      team.upsert_member!(user, "supervisor")
    }.to change { team.team_users.count }.by(1)

    tu = team.team_users.find_by(user_id: user.id)
    expect(tu.role).to eq("supervisor")
  end

  it "updates the role when the user is already on the team" do
    team.upsert_member!(user, "member")

    expect {
      team.upsert_member!(user, "admin")
    }.not_to change { team.team_users.count }

    expect(team.team_users.find_by(user_id: user.id).role).to eq("admin")
  end

  it "returns the persisted team_user" do
    result = team.upsert_member!(user, "member")
    expect(result).to be_persisted
    expect(result).to eq(team.team_users.find_by(user_id: user.id))
  end

  it "returns nil when user is nil (no-op)" do
    expect(team.upsert_member!(nil)).to be_nil
  end

  it "raises ActiveRecord::RecordInvalid when role is outside the canonical set" do
    expect {
      team.upsert_member!(user, "bogus")
    }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it "defaults to role 'member' when none is given" do
    team.upsert_member!(user)
    expect(team.team_users.find_by(user_id: user.id).role).to eq("member")
  end
end
