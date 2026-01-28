class AddDeleteAccountTokenToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :delete_account_token, :string
    add_index :users, :delete_account_token, unique: true
    add_column :users, :delete_account_token_expires_at, :datetime
  end
end
