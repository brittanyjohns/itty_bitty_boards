require "rails_helper"
require Rails.root.join("db/migrate/20260912120000_backfill_team_creator_invitation_accepted_at.rb")

# Issue #923. The rows this migration exists for were written before
# `Team#upsert_member!` stamped `invitation_accepted_at`, so they can only be
# created here by clearing the column behind the writer.
RSpec.describe BackfillTeamCreatorInvitationAcceptedAt do
  let(:migration) { described_class.new }
  let(:owner) { FactoryBot.create(:user, created_at: 2.months.ago) }
  let(:team) { FactoryBot.create(:team, created_by: owner) }

  def legacy_member(user, role)
    tu = team.upsert_member!(user, role)
    tu.update_columns(invitation_accepted_at: nil, created_at: 30.days.ago)
    tu
  end

  before { migration.verbose = false }

  it "backfills a team creator's row to its created_at" do
    tu = legacy_member(owner, "admin")

    migration.up

    expect(tu.reload.invitation_accepted_at).to be_within(1.second).of(tu.created_at)
  end

  it "leaves a non-admin row null — there, null is a real pending invite" do
    supervisor = legacy_member(FactoryBot.create(:user), "supervisor")
    member = legacy_member(FactoryBot.create(:user), "member")
    restricted = legacy_member(FactoryBot.create(:user), "restricted")

    migration.up

    expect(supervisor.reload.invitation_accepted_at).to be_nil
    expect(member.reload.invitation_accepted_at).to be_nil
    expect(restricted.reload.invitation_accepted_at).to be_nil
  end

  it "does not move an admin row that already has an acceptance" do
    tu = team.upsert_member!(owner, "admin")
    tu.update_columns(invitation_accepted_at: 3.days.ago, created_at: 30.days.ago)
    was = tu.reload.invitation_accepted_at

    migration.up

    expect(tu.reload.invitation_accepted_at).to be_within(1.second).of(was)
  end

  it "leaves no team reporting its own owner as 'hasn't joined yet'" do
    legacy_member(owner, "admin")

    migration.up

    expect(TeamUser.where(role: "admin", invitation_accepted_at: nil)).to be_empty
  end
end
