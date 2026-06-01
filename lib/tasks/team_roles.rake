namespace :team_roles do
  # Mapping for non-canonical role strings. Anything not in
  # TeamUser::ROLES and not in this map falls back to "member" so a
  # surprise value never blocks the inclusion validation.
  #
  # See issue #216 and marketing/drafts/role-normalization-notes.md
  # for the reasoning behind each fold.
  ROLE_FOLD = {
    "professional" => "admin",     # creator-add path; always the account owner
    "supporter"    => "member",    # never landed in prod (default arg for add_member!)
    "restricted"   => "member",    # read access preserved; curate access dropped
  }.freeze

  desc "Print every team_users row that would be rewritten by team_roles:normalize"
  task normalize_dry_run: :environment do
    rows = stale_rows
    if rows.empty?
      puts "No team_users rows need normalization. All values already in TeamUser::ROLES."
      next
    end

    puts "Would update #{rows.count} team_users row(s):"
    rows.each do |row|
      target = target_role_for(row.role)
      puts "  ##{row.id} team=#{row.team_id} user=#{row.user_id}: " \
           "#{row.role.inspect} -> #{target.inspect}"
    end
    puts ""
    summary = rows.group_by(&:role).transform_values(&:count)
    puts "By source role: #{summary.inspect}"
  end

  desc "Rewrite stale team_users.role values to the canonical set (admin/supervisor/member)"
  task normalize: :environment do
    updated = 0
    skipped = 0
    stale_rows.each do |row|
      target = target_role_for(row.role)
      if row.role == target
        skipped += 1
        next
      end
      row.update_columns(role: target, updated_at: Time.current)
      updated += 1
    end
    puts "team_roles:normalize complete. updated=#{updated} skipped=#{skipped}"
  end

  def stale_rows
    TeamUser.where.not(role: TeamUser::ROLES).order(:id)
  end

  def target_role_for(role)
    ROLE_FOLD[role.to_s] || "member"
  end
end
