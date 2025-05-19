class AddPlaceholderToAccounts < ActiveRecord::Migration[7.1]
  def up
    add_column :profiles, :placeholder, :boolean, default: false
    add_column :profiles, :claim_token, :string
    add_column :profiles, :claimed_at, :datetime
    change_column_null :profiles, :profileable_type, true
    change_column_null :profiles, :profileable_id, true
  end

  def down
    remove_column :profiles, :placeholder
    remove_column :profiles, :claim_token
    remove_column :profiles, :claimed_at
    change_column_null :profiles, :profileable_type, false
    change_column_null :profiles, :profileable_id, false
  end
end
