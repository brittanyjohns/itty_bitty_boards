# frozen_string_literal: true

require "rails_helper"

# Issue #923 (finding 1) — "joined" is a fact the backend owns.
#
# #914 put `invitation_accepted_at` on the team payload so an owner could tell
# who had actually turned up, but the column was written in exactly one place:
# `TeamUser#accept_invitation!`, reached only by `accept_invite_patch`. The
# team creator never travels that path — her row is made directly when the
# team is created — so her timestamp was permanently null and she rendered on
# her own team as "hasn't joined yet", beside a MEMBERS count of 0.
#
# `upsert_member!` therefore stamps by DEFAULT: putting someone on a team is
# joining. The invite path is the one deliberate exception, and it passes
# `accepted: false`.
RSpec.describe "Team membership joined state", type: :model do
  let(:owner)   { create(:user, created_at: 2.months.ago) }
  let(:invitee) { create(:user, created_at: 2.months.ago) }
  let(:account) { create(:child_account, user: owner, owner: owner) }

  describe "Team#upsert_member!" do
    let(:team) { create(:team, created_by: owner) }

    it "stamps invitation_accepted_at by default" do
      tu = team.upsert_member!(owner, "admin")
      expect(tu.invitation_accepted_at).to be_present
    end

    it "leaves it null when the caller says the person has only been invited" do
      tu = team.upsert_member!(invitee, "member", accepted: false)
      expect(tu.invitation_accepted_at).to be_nil
    end

    it "never clears an existing acceptance on a re-invite" do
      tu = team.upsert_member!(invitee, "member")
      stamped = tu.invitation_accepted_at
      expect(stamped).to be_present

      team.upsert_member!(invitee, "member", accepted: false)
      expect(tu.reload.invitation_accepted_at).to eq(stamped)
    end

    it "does not move an existing acceptance forward" do
      tu = team.upsert_member!(invitee, "member")
      tu.update_columns(invitation_accepted_at: 3.weeks.ago)
      was = tu.reload.invitation_accepted_at

      team.upsert_member!(invitee, "supervisor")
      expect(tu.reload.invitation_accepted_at).to be_within(1.second).of(was)
      expect(tu.role).to eq("supervisor")
    end

    it "stamps a previously-pending invitee once they are added server-side" do
      tu = team.upsert_member!(invitee, "member", accepted: false)
      expect(tu.invitation_accepted_at).to be_nil

      team.upsert_member!(invitee, "supervisor")
      expect(tu.reload.invitation_accepted_at).to be_present
    end
  end

  describe "ChildAccount#ensure_team!" do
    it "reports the creator as joined" do
      team = account.ensure_team!(creator: owner)
      tu = team.team_users.find_by(user_id: owner.id)

      expect(tu.role).to eq("admin")
      expect(tu.invitation_accepted_at).to be_present
    end
  end

  describe "Team#member_views" do
    let(:team) { account.ensure_team!(creator: owner) }

    before { team.upsert_member!(invitee, "member", accepted: false) }

    it "serializes a derived `joined` boolean so the client stops re-deriving it" do
      views = team.reload.member_views(team.account_owner_ids)

      creator = views.find { |v| v[:user_id] == owner.id }
      pending = views.find { |v| v[:user_id] == invitee.id }

      expect(creator[:joined]).to be true
      expect(creator[:invitation_accepted_at]).to be_present

      expect(pending[:joined]).to be false
      expect(pending[:invitation_accepted_at]).to be_nil
    end
  end
end
