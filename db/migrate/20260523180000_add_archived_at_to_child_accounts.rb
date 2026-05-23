class AddArchivedAtToChildAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :child_accounts, :archived_at, :datetime
    add_index :child_accounts, :archived_at
  end
end
