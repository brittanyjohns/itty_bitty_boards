class AddDataToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :data, :jsonb, default: {}
  end
end
