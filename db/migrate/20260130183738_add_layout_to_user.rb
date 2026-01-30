class AddLayoutToUser < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :layout, :jsonb, default: {}
  end
end
