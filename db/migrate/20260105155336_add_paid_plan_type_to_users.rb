class AddPaidPlanTypeToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :paid_plan_type, :string
    User.reset_column_information
    User.where.not(role: "admin").find_each do |user|
      if user.plan_type == "free" || user.plan_type.nil?
        user.update(paid_plan_type: "free")
      else
        user.update(paid_plan_type: user.plan_type)
      end
    end
  end
end
