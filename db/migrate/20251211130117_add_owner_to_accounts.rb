class AddOwnerToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_reference :child_accounts, :owner, foreign_key: { to_table: :users }
    add_column :child_accounts, :is_demo, :boolean, default: false
    add_column :users, :stripe_subscription_id, :string
    ChildAccount.reset_column_information
    User.reset_column_information
    ChildAccount.includes(:user).find_each do |account|
      user = account.user
      next unless user
      if user.plan_type == "pro"
        account.update!(is_demo: true, owner: user)
      else
        account.update!(is_demo: false, owner: user)
      end
    end
  end
end
