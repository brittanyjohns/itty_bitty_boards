class AddDetailsToBetaRequests < ActiveRecord::Migration[7.1]
  def change
    add_column :beta_requests, :details, :jsonb, default: {}
  end
end
