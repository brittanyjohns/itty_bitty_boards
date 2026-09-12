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

  # An invitation shell: the row `TeamsController#invite` mints for an address
  # with no account. It has a pending devise_invitable token, no password it can
  # use, and has never signed in.
  def invite_shell
    User.invite!(email: "shell-#{SecureRandom.hex(4)}@example.com", skip_invitation: true)
  end

  describe "Team#member_views" do
    let(:team) { account.ensure_team!(creator: owner) }
    let(:shell) { invite_shell }

    before { team.upsert_member!(shell, "member", accepted: false) }

    it "serializes a derived `joined` boolean so the client stops re-deriving it" do
      views = team.reload.member_views(team.account_owner_ids)

      creator = views.find { |v| v[:user_id] == owner.id }
      pending = views.find { |v| v[:user_id] == shell.id }

      expect(creator[:joined]).to be true
      expect(creator[:invitation_accepted_at]).to be_present

      expect(pending[:joined]).to be false
      expect(pending[:invitation_accepted_at]).to be_nil
    end
  end

  # Issue #930 — `joined` must not be a proxy for "clicked the accept link".
  #
  # A person who reaches a team by SIGNING IN — because they already had an
  # account, or made one themselves — never travels `accept_invite_patch`, so
  # their stamp stayed null and a Support member reading the roster saw her own
  # row say "Invited — hasn't joined yet".
  describe "TeamUser#joined? for a member who never used the accept link" do
    let(:team) { account.ensure_team!(creator: owner) }

    it "is true for a member whose account has a password" do
      tu = team.upsert_member!(invitee, "member", accepted: false)

      expect(tu.invitation_accepted_at).to be_nil
      expect(tu.joined?).to be true
    end

    it "is false for an invitation shell that has never set a password or signed in" do
      shell = invite_shell
      tu = team.upsert_member!(shell, "member", accepted: false)

      expect(shell.invited_to_sign_up?).to be true
      expect(tu.joined?).to be false
    end

    it "is true once the shell sets a password" do
      shell = invite_shell
      tu = team.upsert_member!(shell, "member", accepted: false)

      shell.password = "password123"
      shell.password_confirmation = "password123"
      expect(shell.accept_invitation!).to be_truthy

      expect(TeamUser.find(tu.id).joined?).to be true
    end

    # email_signup, Google sign-in and the Stripe webhook all create users with
    # `User.invite!`, so a pending invitation token does NOT mean "cannot get
    # in" — those people sign in without ever setting a password.
    it "is true for a passwordless account that has signed in" do
      passwordless = invite_shell
      passwordless.update_columns(sign_in_count: 1, last_sign_in_at: 1.day.ago)
      tu = team.upsert_member!(passwordless, "member", accepted: false)

      expect(passwordless.reload.invited_to_sign_up?).to be true
      expect(TeamUser.find(tu.id).joined?).to be true
    end

    it "is false, not an error, when the user has been soft-deleted" do
      tu = team.upsert_member!(invitee, "member", accepted: false)
      invitee.update_columns(deleted_at: Time.current)

      reloaded = TeamUser.find(tu.id)
      expect(reloaded.user).to be_nil
      expect(reloaded.joined?).to be false
    end

    it "counts a signed-in member as joined on the roster and a shell as invited" do
      shell = invite_shell
      team.upsert_member!(invitee, "member", accepted: false)
      team.upsert_member!(shell, "member", accepted: false)

      views = team.reload.member_views(team.account_owner_ids)

      expect(views.select { |v| v[:joined] }.map { |v| v[:user_id] }).to contain_exactly(owner.id, invitee.id)
      expect(views.reject { |v| v[:joined] }.map { |v| v[:user_id] }).to contain_exactly(shell.id)
    end

    it "agrees in TeamUser#api_view" do
      tu = team.upsert_member!(invitee, "member", accepted: false)

      expect(tu.api_view[:joined]).to be true
    end
  end
end
