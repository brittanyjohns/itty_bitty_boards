# frozen_string_literal: true

require "rails_helper"

# Issue #216 / team permissions overhaul — `team_users.role` is locked to the
# canonical set `%w[admin supervisor member restricted]`. Permissions matrix:
# marketing/.claude-notes/handoff-workflow.md.
RSpec.describe TeamUser, type: :model do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) { create(:child_account, user: owner, owner: owner) }
  let(:team) { account.ensure_team!(creator: owner) }

  describe "role inclusion validation" do
    TeamUser::ROLES.each do |role|
      it "accepts #{role.inspect}" do
        user = create(:user, created_at: 2.months.ago)
        tu = TeamUser.new(team: team, user: user, role: role)
        expect(tu).to be_valid
      end
    end

    %w[professional supporter slp parent foo].each do |stale|
      it "rejects #{stale.inspect}" do
        user = create(:user, created_at: 2.months.ago)
        tu = TeamUser.new(team: team, user: user, role: stale)
        expect(tu).not_to be_valid
        expect(tu.errors[:role]).to be_present
      end
    end

    it "fills the default ('member') when role is blank on create" do
      user = create(:user, created_at: 2.months.ago)
      tu = TeamUser.create!(team: team, user: user)
      expect(tu.role).to eq("member")
    end
  end

  describe ".roles" do
    it "lists every canonical role" do
      expect(TeamUser.roles.keys).to match_array(TeamUser::ROLES)
    end
  end
end
