class AddPasscodeToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :child_accounts, :passcode, :string
  end
end
