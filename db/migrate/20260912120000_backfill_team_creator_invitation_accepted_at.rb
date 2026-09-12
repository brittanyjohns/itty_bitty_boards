class BackfillTeamCreatorInvitationAcceptedAt < ActiveRecord::Migration[8.0]
  # Issue #923. `invitation_accepted_at` was written in exactly one place —
  # `TeamUser#accept_invitation!`, reached only by the accept-invite endpoint —
  # and a team creator never travels that path: her row is made directly when
  # the team is created. So her timestamp was permanently null and every team
  # in the database reported its own owner as "hasn't joined yet", beside a
  # MEMBERS count of 0.
  #
  # Scoped to `role: "admin"` on purpose. `admin` is absent from
  # `TeamUser::ASSIGNABLE_ROLES` and rejected by `TeamsController#invite_role`,
  # so an admin row can only ever have been created server-side — it is never
  # a pending invitation, and backfilling it invents nothing.
  #
  # Non-admin nulls are deliberately LEFT ALONE. There, null is genuinely
  # ambiguous (a supervisor who joined years ago and an invitee who never
  # opened the email look identical), and stamping them would destroy the
  # pending-invite signal #914 added for every existing team.
  #
  # `created_at` is the defensible value: the creator was on the team from the
  # instant it existed.
  def up
    scope = TeamUser.where(role: "admin", invitation_accepted_at: nil)
    count = scope.count

    scope.update_all("invitation_accepted_at = created_at")

    say "Backfilled invitation_accepted_at on #{count} team creator row(s)"
  end

  def down
    # Not reversible: the pre-migration state is indistinguishable from a row
    # that was legitimately null, and re-nulling every admin row would also
    # clear acceptances written after this migration ran.
    say "BackfillTeamCreatorInvitationAcceptedAt is not reversible; no changes made"
  end
end
