# frozen_string_literal: true

require "rails_helper"
require "rake"

# Issue #216 — operator can preview the role-normalization fold with
# `team_roles:normalize_dry_run` before running `team_roles:normalize`.
# The migration (db/migrate/...normalize_team_users_role.rb) does the
# same work on deploy; the rake task is the dress-rehearsal.
RSpec.describe "team_roles rake tasks", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:dry_run) { Rake::Task["team_roles:normalize_dry_run"] }
  let(:normalize) { Rake::Task["team_roles:normalize"] }
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) { create(:child_account, user: owner, owner: owner) }
  let!(:team) { account.ensure_team!(creator: owner) }

  after do
    dry_run.reenable
    normalize.reenable
  end

  def insert_team_user_with_role(role)
    user = create(:user, created_at: 2.months.ago)
    # Bypass the inclusion validation so we can simulate legacy rows.
    TeamUser.new(team: team, user: user, role: role).save(validate: false)
    TeamUser.where(team: team, user: user).first
  end

  describe "team_roles:normalize_dry_run" do
    it "doesn't mutate anything" do
      tu = insert_team_user_with_role("professional")
      expect { silent { dry_run.invoke } }.not_to(change { tu.reload.role })
    end

    it "prints the no-op message when every row is already canonical" do
      output = capture_stdout { dry_run.invoke }
      expect(output).to match(/No team_users rows need normalization/)
    end
  end

  describe "team_roles:normalize" do
    it "rewrites professional -> admin" do
      tu = insert_team_user_with_role("professional")
      silent { normalize.invoke }
      expect(tu.reload.role).to eq("admin")
    end

    it "rewrites supporter -> member" do
      tu = insert_team_user_with_role("supporter")
      silent { normalize.invoke }
      expect(tu.reload.role).to eq("member")
    end

    it "leaves restricted untouched (canonical since the 4-tier overhaul)" do
      tu = insert_team_user_with_role("restricted")
      silent { normalize.invoke }
      expect(tu.reload.role).to eq("restricted")
    end

    it "rewrites unknown values -> member (defensive)" do
      tu = insert_team_user_with_role("slp")
      silent { normalize.invoke }
      expect(tu.reload.role).to eq("member")
    end

    it "leaves canonical roles untouched" do
      tu_admin      = insert_team_user_with_role("admin")
      tu_supervisor = insert_team_user_with_role("supervisor")
      tu_member     = insert_team_user_with_role("member")

      silent { normalize.invoke }

      expect(tu_admin.reload.role).to eq("admin")
      expect(tu_supervisor.reload.role).to eq("supervisor")
      expect(tu_member.reload.role).to eq("member")
    end
  end

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def silent
    capture_stdout { yield }
  end
end
