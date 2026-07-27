class AddEmailVerification < ActiveRecord::Migration[8.0]
  def up
    add_column :users, :email_verification_token, :string
    add_column :users, :email_verification_sent_at, :datetime
    add_index :users, :email_verification_token, unique: true

    # Backfill: every account that exists today is treated as verified, so no
    # current user sees a banner or loses tokens. Raw SQL on purpose — User has
    # `default_scope { where(deleted_at: nil) }`, and soft-deleted rows must be
    # backfilled too (they can be restored).
    execute <<~SQL
      UPDATE users SET confirmed_at = created_at WHERE confirmed_at IS NULL
    SQL
  end

  def down
    remove_index :users, :email_verification_token
    remove_column :users, :email_verification_token
    remove_column :users, :email_verification_sent_at
  end
end
