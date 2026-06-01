# frozen_string_literal: true

require "rails_helper"

# Issue #216 — `can_add_boards_to_account?` is the "curate boards on
# the communicator" gate. Only admin (account owner) and supervisor
# (power collaborator) curate. `member` is read-only on the
# communicator; they can add boards to the team library but cannot
# push them onto the communicator. Full matrix in
# marketing/.claude-notes/handoff-workflow.md.
RSpec.describe User, "#can_add_boards_to_account?", type: :model do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) do
    create(:child_account, user: owner, owner: owner, status: ChildAccount::ACTIVE)
  end
  let!(:team) { account.ensure_team!(creator: owner) }

  it "is true for the account owner" do
    expect(owner.can_add_boards_to_account?([account.id])).to be true
  end

  it "is true for a system admin" do
    sys_admin = create(:admin_user)
    expect(sys_admin.can_add_boards_to_account?([account.id])).to be true
  end

  it "is true for a team member with role 'admin'" do
    user = create(:user, created_at: 2.months.ago)
    team.upsert_member!(user, "admin")
    expect(user.can_add_boards_to_account?([account.id])).to be true
  end

  it "is true for a team member with role 'supervisor'" do
    user = create(:user, created_at: 2.months.ago)
    team.upsert_member!(user, "supervisor")
    expect(user.can_add_boards_to_account?([account.id])).to be true
  end

  it "is false for a team member with role 'member' (read-only on the communicator)" do
    user = create(:user, created_at: 2.months.ago)
    team.upsert_member!(user, "member")
    expect(user.can_add_boards_to_account?([account.id])).to be false
  end

  it "is false for a stranger who isn't on any team for the account" do
    stranger = create(:user, created_at: 2.months.ago)
    expect(stranger.can_add_boards_to_account?([account.id])).to be false
  end
end
