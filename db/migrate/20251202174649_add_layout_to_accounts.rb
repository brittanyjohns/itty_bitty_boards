class AddLayoutToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :child_accounts, :layout, :jsonb, default: {}
  end
end
