class AddVendorIdToChildAccount < ActiveRecord::Migration[7.1]
  def up
    add_reference :child_accounts, :vendor, foreign_key: true, null: true if !column_exists?(:child_accounts, :vendor_id)
    add_reference :word_events, :vendor, foreign_key: true, null: true if !column_exists?(:word_events, :vendor_id)
  end

  def down
    remove_reference :child_accounts, :vendor, foreign_key: true if column_exists?(:child_accounts, :vendor_id)
    remove_reference :word_events, :vendor, foreign_key: true if column_exists?(:word_events, :vendor_id)
  end
end
