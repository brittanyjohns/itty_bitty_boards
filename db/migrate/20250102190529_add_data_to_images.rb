class AddDataToImages < ActiveRecord::Migration[7.1]
  def up
    add_column :images, :data, :jsonb, default: {} if !column_exists?(:images, :data)
    add_column :images, :license, :jsonb, default: {} if !column_exists?(:images, :license)
    add_column :images, :obf_id, :string if !column_exists?(:images, :obf_id)
    add_index :images, :obf_id, unique: true if !index_exists?(:images, :obf_id)
  end

  def down
    remove_column :images, :data if column_exists?(:images, :data)
    remove_column :images, :license if column_exists?(:images, :license)
    remove_column :images, :obf_id if column_exists?(:images, :obf_id)
    remove_index :images, :obf_id if index_exists?(:images, :obf_id)
  end
end
