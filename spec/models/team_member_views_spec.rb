# frozen_string_literal: true

require "rails_helper"

# Issue #914 — an invited person and a joined person were indistinguishable to
# the team owner. `TeamsController#invite` calls `upsert_member!`
# unconditionally, so an invitee is a full member row from the moment the POST
# returns; without an acceptance field on the payload the roster counted four
# people who might never arrive as members.
#
# #923 moved the stamp into `upsert_member!` itself: being added to a team IS
# joining, and `TeamsController#invite` is the one caller that passes
# `accepted: false`. So an "invited but not joined" row is created that way
# here, exactly as the invite path creates it.
RSpec.describe Team, "#member_views", type: :model do
  let(:owner) { create(:user, created_at: 2.months.ago) }
  let(:account) { create(:child_account, user: owner, owner: owner) }
  let(:team) { account.ensure_team!(creator: owner) }
  let(:invitee) { create(:user, created_at: 2.months.ago) }

  def view_for(user)
    team.show_api_view(owner)[:members].find { |m| m[:user_id] == user.id }
  end

  it "reports nil acceptance for a member who has been invited but has not joined" do
    team.upsert_member!(invitee, "supervisor", accepted: false)

    row = view_for(invitee)
    expect(row).to be_present
    expect(row).to have_key(:invitation_accepted_at)
    expect(row[:invitation_accepted_at]).to be_nil
    expect(row[:joined]).to be false
  end

  it "reports the acceptance timestamp once the member joins" do
    team.upsert_member!(invitee, "supervisor", accepted: false)
    TeamUser.find_by(user_id: invitee.id, team_id: team.id).accept_invitation!

    expect(view_for(invitee)[:invitation_accepted_at]).to be_present
    expect(view_for(invitee)[:joined]).to be true
  end

  it "distinguishes an invited member from a joined one in the same payload" do
    joined = create(:user, created_at: 2.months.ago)
    team.upsert_member!(joined, "member", accepted: false)
    TeamUser.find_by(user_id: joined.id, team_id: team.id).accept_invitation!
    team.upsert_member!(invitee, "member", accepted: false)

    expect(view_for(joined)[:invitation_accepted_at]).to be_present
    expect(view_for(invitee)[:invitation_accepted_at]).to be_nil
  end

  # The bug #923 was filed for: the creator never travels the accept path, so
  # her own team reported her as "hasn't joined yet" beside a MEMBERS count of 0.
  it "reports the team creator as joined" do
    row = view_for(owner)

    expect(row[:role]).to eq("admin")
    expect(row[:invitation_accepted_at]).to be_present
    expect(row[:joined]).to be true
  end

  it "carries the field on the index view too" do
    team.upsert_member!(invitee, "restricted", accepted: false)

    row = team.index_api_view(owner)[:members].find { |m| m[:user_id] == invitee.id }
    expect(row).to have_key(:invitation_accepted_at)
    expect(row).to have_key(:joined)
  end

  # The field is additive — nothing that already read this payload may break.
  it "keeps the existing member keys" do
    team.upsert_member!(invitee, "supervisor")

    row = view_for(invitee)
    expect(row).to include(:id, :user_id, :name, :email, :role, :plan_type, :is_account_owner,
                           :invitation_accepted_at, :joined)
    expect(row[:role]).to eq("supervisor")
  end
end
