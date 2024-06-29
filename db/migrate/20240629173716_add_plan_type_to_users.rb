class AddPlanTypeToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :plan_type, :string, default: "free"
    add_column :users, :plan_expires_at, :datetime
    add_column :users, :plan_status, :string, default: "active"
    add_column :users, :monthly_price, :decimal, precision: 8, scale: 2, default: 0.0
    add_column :users, :yearly_price, :decimal, precision: 8, scale: 2, default: 0.0
    add_column :users, :total_plan_cost, :decimal, precision: 8, scale: 2, default: 0.0
  end
end
