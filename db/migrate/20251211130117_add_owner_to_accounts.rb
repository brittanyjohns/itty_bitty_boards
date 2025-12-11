class AddOwnerToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_reference :child_accounts, :owner, foreign_key: { to_table: :users }
    add_column :child_accounts, :plan_type, :string, default: "demo", null: false
    add_column :users, :stripe_subscription_id, :string
  end
end
