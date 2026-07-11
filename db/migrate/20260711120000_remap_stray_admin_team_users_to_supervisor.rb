class RemapStrayAdminTeamUsersToSupervisor < ActiveRecord::Migration[8.0]
  # Safety sweep (Phase 2). `admin` is now strictly the team owner's role.
  # Any team_user carrying role `admin` who is neither the team creator nor a
  # communicator account owner on that team is a stray from the old model and
  # is remapped to `supervisor` (the closest curate role). No users are on
  # teams yet, so this is expected to touch ~0 rows.
  def up
    remapped = 0

    TeamUser.where(role: "admin").includes(team: :team_accounts).find_each do |tu|
      team = tu.team
      next if team.nil?
      next if team.created_by_id == tu.user_id
      next if team.account_owner?(tu.user)

      tu.update_columns(role: "supervisor", updated_at: Time.current)
      remapped += 1
    end

    say "Remapped #{remapped} stray admin team_user(s) to supervisor"
  end

  def down
    # Not reversibly restorable — the pre-migration role of a remapped row
    # isn't recorded (it was uniformly `admin`), and blindly promoting every
    # supervisor back to admin would corrupt legitimately-supervisor rows.
    # A no-op keeps the migration reversible-safe without destroying data.
    say "RemapStrayAdminTeamUsersToSupervisor is not reversible; no changes made"
  end
end
