class AddVendorIdToUsers < ActiveRecord::Migration[7.1]
  def up
    add_reference :users, :vendor, foreign_key: true, null: true if !column_exists?(:users, :vendor_id)
    add_index :users, :vendor_id if !index_exists?(:users, :vendor_id)
    add_reference :boards, :vendor, foreign_key: true, null: true if !column_exists?(:boards, :vendor_id)
    add_index :boards, :vendor_id if !index_exists?(:boards, :vendor_id)
  end

  def down
    remove_reference :users, :vendor, foreign_key: true if column_exists?(:users, :vendor_id)
    remove_index :users, :vendor_id if index_exists?(:users, :vendor_id)
    remove_reference :boards, :vendor, foreign_key: true if column_exists?(:boards, :vendor_id)
    remove_index :boards, :vendor_id if index_exists?(:boards, :vendor_id)
  end
end
