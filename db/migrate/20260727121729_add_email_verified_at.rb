class AddEmailVerifiedAt < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :email_verified_at, :datetime

    # Everyone who exists today is treated as verified — nobody loses grants or
    # sees a banner. Raw SQL because User has default_scope { where(deleted_at: nil) }
    # and soft-deleted rows must be backfilled too.
    execute <<~SQL
      UPDATE users SET email_verified_at = created_at
    SQL
  end

  def down
    remove_column :users, :email_verified_at
  end
end
