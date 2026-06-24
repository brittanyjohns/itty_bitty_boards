# frozen_string_literal: true

require "rails_helper"
require "rake"

# Repair task for the hand-off team-membership bug. Reconstructs a stale
# post-claim state (new owner missing from the communicator's own team) and
# verifies the task heals it without touching unrelated shared teams.
RSpec.describe "communicators:repair_handoff_teams", type: :task do
  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  let(:task) { Rake::Task["communicators:repair_handoff_teams"] }
  let(:old_owner) { create(:user, plan_type: "pro", created_at: 3.months.ago) }
  let(:new_owner) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

  after do
    task.reenable
    ENV.delete("DRY_RUN")
    ENV.delete("USER_ID")
  end

  # An active communicator whose OWN (namesake) team was never updated at
  # claim time: it still has only the previous owner as admin.
  def broken_handoff(name: "Newton")
    ca = create(:child_account, user: new_owner, owner: new_owner, status: "active",
                                passcode: "x", name: name, claimed_at: 1.day.ago)
    namesake = Team.create!(name: "#{name}'s Communication Team", created_by: old_owner)
    TeamAccount.create!(team: namesake, account: ca)
    namesake.upsert_member!(old_owner, "admin")
    [ca.reload, namesake]
  end

  def silent
    original = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original
  end

  it "dry-run reports but does not mutate" do
    ca, namesake = broken_handoff

    silent { task.invoke }

    expect(namesake.team_users.find_by(user_id: new_owner.id)).to be_nil
    expect(namesake.reload.created_by_id).to eq(old_owner.id)
    expect(ca.reload.settings["primary_team_id"]).to be_nil
  end

  it "repairs the own team: new owner admin, prev owner supervisor, ownership transferred" do
    ca, namesake = broken_handoff
    ENV["DRY_RUN"] = "false"

    silent { task.invoke }

    expect(namesake.team_users.find_by(user_id: new_owner.id)&.role).to eq("admin")
    expect(namesake.team_users.find_by(user_id: old_owner.id)&.role).to eq("supervisor")
    expect(namesake.reload.created_by_id).to eq(new_owner.id)
    expect(ca.reload.settings["primary_team_id"]).to eq(namesake.id)
  end

  it "leaves an unrelated shared team alone" do
    ca, _namesake = broken_handoff
    shared = Team.create!(name: "Shared Crew", created_by: old_owner)
    TeamAccount.create!(team: shared, account: ca)
    # Make it genuinely shared (a second account), so it can't be mistaken
    # for this communicator's own team.
    other = create(:child_account, user: old_owner, owner: old_owner, status: "active",
                                   passcode: "y", username: "other-#{SecureRandom.hex(2)}")
    TeamAccount.create!(team: shared, account: other)
    shared.upsert_member!(old_owner, "admin")
    ENV["DRY_RUN"] = "false"

    silent { task.invoke }

    expect(shared.team_users.find_by(user_id: new_owner.id)).to be_nil
    expect(shared.reload.created_by_id).to eq(old_owner.id)
  end

  it "skips a communicator with no identifiable own team" do
    # Active claimed communicator that only lives on a shared team.
    ca = create(:child_account, user: new_owner, owner: new_owner, status: "active",
                                passcode: "x", claimed_at: 1.day.ago, name: "Lonely")
    shared = Team.create!(name: "Shared Crew", created_by: old_owner)
    TeamAccount.create!(team: shared, account: ca)
    other = create(:child_account, user: old_owner, owner: old_owner, status: "active",
                                   passcode: "y", username: "o-#{SecureRandom.hex(2)}")
    TeamAccount.create!(team: shared, account: other)
    shared.upsert_member!(old_owner, "admin")
    ENV["DRY_RUN"] = "false"

    silent { task.invoke }

    expect(shared.team_users.find_by(user_id: new_owner.id)).to be_nil
    expect(ca.reload.settings["primary_team_id"]).to be_nil
  end

  it "registers the communicator's dashboard boards as team boards" do
    ca, namesake = broken_handoff
    board = create(:board, user: old_owner, name: "Inherited")
    create(:child_board, board: board, child_account: ca)
    ENV["DRY_RUN"] = "false"

    silent { task.invoke }

    expect(namesake.reload.boards).to include(board)
  end

  it "is idempotent — a second run makes no further changes" do
    ca, namesake = broken_handoff
    ENV["DRY_RUN"] = "false"

    silent { task.invoke }
    task.reenable
    expect { silent { task.invoke } }.not_to(change { namesake.reload.updated_at })
    expect(namesake.reload.created_by_id).to eq(new_owner.id)
    expect(ca.reload.settings["primary_team_id"]).to eq(namesake.id)
  end
end
