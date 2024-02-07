class AddOsStatusToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :open_symbol_status, :string, default: "active"
  end
end
