class AddCreditBalancesToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :plan_credits_balance, :integer, default: 0, null: false
    add_column :users, :topup_credits_balance, :integer, default: 0, null: false
    add_column :users, :plan_credits_reset_at, :datetime
  end
end
