class AddClaimToChildAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :child_accounts, :claim_token, :string
    add_column :child_accounts, :claim_token_sent_at, :datetime
    add_column :child_accounts, :claimed_at, :datetime
    add_column :child_accounts, :loaner_started_at, :datetime
    add_column :child_accounts, :reclaimed_at, :datetime

    add_index :child_accounts, :claim_token, unique: true
    add_index :child_accounts, :loaner_started_at
  end
end
