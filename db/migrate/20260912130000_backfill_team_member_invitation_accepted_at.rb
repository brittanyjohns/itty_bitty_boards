class BackfillTeamMemberInvitationAcceptedAt < ActiveRecord::Migration[8.0]
  # Issue #930. `TeamUser#joined?` now means "used the accept link OR has a
  # working account" (`User#working_account?`), because a member who reaches a
  # team by SIGNING IN never travels `accept_invite_patch` and was reported as
  # never having arrived. This stamps the existing rows so the timestamp and the
  # boolean agree.
  #
  # The condition is `User#working_account?` in SQL: the account has no pending
  # invitation token (it has a usable password or was never invited), OR it has
  # signed in at least once (passwordless email/Google accounts carry a token
  # but do sign in). An invitation shell — pending token, never signed in — is
  # left null, because there null is still a real pending invite (#914).
  #
  # Value: the later of when they were put on the team and when the account
  # accepted its own devise invitation — a shell that set its password after
  # the team invite arrived then, not when the owner pressed Invite.
  def up
    count = exec_update(<<~SQL.squish)
      UPDATE team_users
      SET invitation_accepted_at = GREATEST(team_users.created_at, users.invitation_accepted_at)
      FROM users
      WHERE users.id = team_users.user_id
        AND team_users.invitation_accepted_at IS NULL
        AND users.deleted_at IS NULL
        AND (
          users.invitation_token IS NULL
          OR users.sign_in_count > 0
          OR users.last_sign_in_at IS NOT NULL
        )
    SQL

    say "Backfilled invitation_accepted_at on #{count} team member row(s) with a working account"
  end

  def down
    # Not reversible: a stamped row is indistinguishable from one written by a
    # real acceptance after this ran.
    say "BackfillTeamMemberInvitationAcceptedAt is not reversible; no changes made"
  end
end
