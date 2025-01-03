class AddDataToImages < ActiveRecord::Migration[7.1]
  def change
    add_column :images, :data, :jsonb, default: {}
    add_column :images, :license, :jsonb, default: {}
    add_column :images, :obf_id, :string
  end
end
