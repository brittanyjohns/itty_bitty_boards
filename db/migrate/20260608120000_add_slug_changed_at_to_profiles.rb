class AddSlugChangedAtToProfiles < ActiveRecord::Migration[7.1]
  def up
    add_column :profiles, :slug_changed_at, :datetime

    # Backfill from created_at so the first edit window opens immediately for
    # all existing rows. The 7-day clock starts on the NEXT edit, not on this
    # backfill.
    execute "UPDATE profiles SET slug_changed_at = created_at WHERE slug_changed_at IS NULL"
  end

  def down
    remove_column :profiles, :slug_changed_at
  end
end
