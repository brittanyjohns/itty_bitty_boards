require "rails_helper"
require Rails.root.join("db/migrate/20260912130000_backfill_team_member_invitation_accepted_at.rb")

# Issue #930. Members who reached a team by signing in — rather than through
# the accept link — were left with a null `invitation_accepted_at`. `joined?`
# now derives from the account itself, and this stamps the existing rows so the
# timestamp agrees with the boolean.
RSpec.describe BackfillTeamMemberInvitationAcceptedAt do
  let(:migration) { described_class.new }
  let(:owner) { FactoryBot.create(:user, created_at: 2.months.ago) }
  let(:team) { FactoryBot.create(:team, created_by: owner) }

  def pending_member(user, role = "member", created_at: 30.days.ago)
    tu = team.upsert_member!(user, role, accepted: false)
    tu.update_columns(created_at: created_at)
    tu
  end

  def invite_shell
    User.invite!(email: "shell-#{SecureRandom.hex(4)}@example.com", skip_invitation: true)
  end

  before { migration.verbose = false }

  it "stamps a member whose account has a password, to when they joined the team" do
    tu = pending_member(FactoryBot.create(:user))

    migration.up

    expect(tu.reload.invitation_accepted_at).to be_within(1.second).of(tu.created_at)
  end

  it "stamps a passwordless member who has signed in" do
    user = invite_shell
    user.update_columns(sign_in_count: 2, last_sign_in_at: 1.day.ago)
    tu = pending_member(user)

    migration.up

    expect(tu.reload.invitation_accepted_at).to be_present
  end

  it "uses the account's own acceptance when that came after the team invite" do
    user = invite_shell
    tu = pending_member(user, created_at: 30.days.ago)
    accepted = 10.days.ago.change(usec: 0)
    user.update_columns(invitation_token: nil, invitation_accepted_at: accepted)

    migration.up

    expect(tu.reload.invitation_accepted_at).to be_within(1.second).of(accepted)
  end

  it "leaves an invitation shell null — there, null is a real pending invite" do
    tu = pending_member(invite_shell)

    migration.up

    expect(tu.reload.invitation_accepted_at).to be_nil
  end

  it "does not move an existing acceptance" do
    tu = pending_member(FactoryBot.create(:user))
    tu.update_columns(invitation_accepted_at: 3.days.ago)
    was = tu.reload.invitation_accepted_at

    migration.up

    expect(tu.reload.invitation_accepted_at).to be_within(1.second).of(was)
  end

  it "leaves the stamp and joined? agreeing for every row" do
    pending_member(FactoryBot.create(:user))
    pending_member(invite_shell)

    migration.up

    team.team_users.includes(:user).each do |tu|
      expect(tu.invitation_accepted_at.present?).to eq(tu.joined?)
    end
  end
end
