class NormalizeTeamUsersRole < ActiveRecord::Migration[7.1]
  # Canonical set is admin/supervisor/member. See issue #216 and
  # marketing/drafts/role-normalization-notes.md. Same fold map as
  # lib/tasks/team_roles.rake — duplicated here to keep the migration
  # self-contained (rake constants aren't loaded reliably in migrations).
  FOLD = {
    "professional" => "admin",
    "supporter"    => "member",
    "restricted"   => "member",
  }.freeze
  CANONICAL = %w[admin supervisor member].freeze

  def up
    say_with_time "Normalizing team_users.role values" do
      total = 0
      FOLD.each do |from, to|
        count = execute(
          ActiveRecord::Base.send(:sanitize_sql_array,
                                  ["UPDATE team_users SET role = ?, updated_at = NOW() WHERE role = ?", to, from])
        ).cmd_tuples
        say "#{from.inspect} -> #{to.inspect}: #{count}", true
        total += count
      end

      # Defensive: anything still out of the canonical set falls back
      # to "member". This catches NULLs and any unanticipated string
      # so the upcoming inclusion validation won't trip on legacy data.
      defensive = execute(
        ActiveRecord::Base.send(:sanitize_sql_array,
                                ["UPDATE team_users SET role = ?, updated_at = NOW() WHERE role IS NULL OR role NOT IN (?)",
                                 "member", CANONICAL])
      ).cmd_tuples
      say "defensive (NULL/unknown -> \"member\"): #{defensive}", true
      total += defensive
      say "Total rows updated: #{total}", true
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
