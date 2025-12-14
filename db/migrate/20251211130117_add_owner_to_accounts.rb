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
        user.settings ||= {}
        user.settings["demo_communicator_limit"] = 10
        user.settings["paid_communicator_limit"] = 3
        user.settings["board_limit"] = 200
        user.settings["ai_daily_limit"] = 100
        user.save!
        account.update!(is_demo: true, owner: user)
      elsif user.plan_type == "myspeak"
        user.settings ||= {}
        user.settings["demo_communicator_limit"] = 1
        user.settings["paid_communicator_limit"] = 0
        user.settings["board_limit"] = 3
        user.settings["ai_daily_limit"] = 3
        user.save!
        account.update!(is_demo: true, owner: user)
      elsif user.plan_type == "basic"
        user.settings ||= {}
        user.settings["demo_communicator_limit"] = 0
        user.settings["paid_communicator_limit"] = 2
        user.settings["board_limit"] = 100
        user.settings["ai_daily_limit"] = 50
        user.save!
        account.update!(is_demo: false, owner: user)
      else
        user.plan_type = "free"
        user.settings ||= {}
        user.settings["demo_communicator_limit"] = 0
        user.settings["paid_communicator_limit"] = 0
        user.settings["board_limit"] = 1
        user.settings["ai_daily_limit"] = 3
        user.save!
        account.update!(is_demo: true, owner: user)
      end
    end
  end
end
