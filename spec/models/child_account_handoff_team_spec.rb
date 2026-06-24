# frozen_string_literal: true

require "rails_helper"

# Regression coverage for the hand-off team-membership bug: claim_by! used
# `teams.first`, which is unreliable when a communicator belongs to more than
# one team — the hand-off updated the wrong team and left the communicator's
# OWN team with the new owner missing. See ChildAccount#primary_team and the
# `communicators:repair_handoff_teams` rake task.
RSpec.describe ChildAccount, "hand-off team membership", type: :model do
  let(:slp) { create(:user, plan_type: "pro", created_at: 2.months.ago) }

  def make_parent(plan)
    u = create(:user, plan_type: plan, created_at: 2.months.ago)
    case plan
    when "free"  then u.setup_free_limits
    when "basic" then u.setup_basic_limits
    when "pro"   then u.setup_pro_limits
    end
    u.save!
    u
  end

  # A loaner that belongs to TWO teams, mimicking production: an unrelated
  # shared team created first (so it sorts first by id), plus the
  # communicator's own namesake team. No primary_team_id is pinned, so this
  # exercises the namesake-name fallback (the legacy-data path).
  def loaner_on_two_teams(name: "Newton")
    loaner = create(:child_account, user: slp, owner: slp, status: "loaner",
                                    passcode: "loaner01", name: name)
    shared = Team.create!(name: "Shared Crew", created_by: slp)
    TeamAccount.create!(team: shared, account: loaner)
    shared.upsert_member!(slp, "admin")

    namesake = Team.create!(name: "#{name}'s Communication Team", created_by: slp)
    TeamAccount.create!(team: namesake, account: loaner)
    namesake.upsert_member!(slp, "admin")

    [loaner.reload, shared, namesake]
  end

  describe "#primary_team resolution" do
    it "prefers the namesake team over an earlier-created shared team" do
      loaner, shared, namesake = loaner_on_two_teams

      # `teams.first` (the old behavior) would return the shared team.
      expect(loaner.teams.order(:id).first).to eq(shared)
      expect(loaner.primary_team).to eq(namesake)
    end

    it "prefers a pinned primary_team_id over the namesake name" do
      loaner, shared, _namesake = loaner_on_two_teams
      loaner.pin_primary_team!(shared)

      expect(loaner.reload.primary_team).to eq(shared)
    end
  end

  describe "#ensure_team! pins the created team" do
    it "records primary_team_id so resolution is unambiguous" do
      loaner = create(:child_account, user: slp, owner: slp, status: "loaner", passcode: "x")
      team = loaner.ensure_team!(creator: slp)

      expect(loaner.reload.settings["primary_team_id"]).to eq(team.id)
      expect(loaner.primary_team).to eq(team)
    end
  end

  describe "#claim_by! across plan tiers" do
    %w[free basic pro].each do |plan|
      context "Pro SLP -> #{plan} family" do
        it "updates the communicator's OWN team and leaves shared teams alone" do
          loaner, shared, namesake = loaner_on_two_teams
          parent = make_parent(plan)

          loaner.claim_by!(user: parent)

          # Ownership transferred on the account itself.
          expect(loaner.reload.owner_id).to eq(parent.id)
          expect(loaner.status).to eq("active")

          # Own (namesake) team: new owner admin, old owner supervisor.
          expect(namesake.team_users.find_by(user_id: parent.id)&.role).to eq("admin")
          expect(namesake.team_users.find_by(user_id: slp.id)&.role).to eq("supervisor")

          # Team management transferred to the new owner.
          expect(namesake.reload.created_by_id).to eq(parent.id)

          # primary_team pinned to the namesake team.
          expect(loaner.reload.settings["primary_team_id"]).to eq(namesake.id)

          # The unrelated shared team is untouched.
          expect(shared.team_users.find_by(user_id: parent.id)).to be_nil
          expect(shared.reload.created_by_id).to eq(slp.id)
          expect(shared.team_users.find_by(user_id: slp.id).role).to eq("admin")
        end
      end
    end

    it "registers the communicator's dashboard boards as team boards (preservation safety net)" do
      loaner, _shared, namesake = loaner_on_two_teams
      parent = make_parent("pro")
      b1 = create(:board, user: slp, name: "Board One")
      b2 = create(:board, user: slp, name: "Board Two")
      create(:child_board, board: b1, child_account: loaner)
      create(:child_board, board: b2, child_account: loaner)

      loaner.claim_by!(user: parent)

      expect(namesake.reload.boards).to include(b1, b2)
    end

    it "creates and uses an own team when the communicator has none" do
      loaner = create(:child_account, user: slp, owner: slp, status: "loaner", passcode: "x")
      parent = make_parent("pro")

      loaner.claim_by!(user: parent)

      team = loaner.reload.primary_team
      expect(team).to be_present
      expect(team.team_users.find_by(user_id: parent.id)&.role).to eq("admin")
      expect(team.team_users.find_by(user_id: slp.id)&.role).to eq("supervisor")
      expect(team.created_by_id).to eq(parent.id)
      expect(loaner.settings["primary_team_id"]).to eq(team.id)
    end
  end
end
