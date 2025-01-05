class FixObfImageIndex < ActiveRecord::Migration[7.1]
  def up
    remove_index :images, :obf_id, unique: true
    add_index :images, :obf_id
  end

  def down
    remove_index :images, :obf_id
    add_index :images, :obf_id
  end
end
