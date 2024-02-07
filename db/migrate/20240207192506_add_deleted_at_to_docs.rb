class AddDeletedAtToDocs < ActiveRecord::Migration[7.1]
  def change
    add_column :docs, :deleted_at, :datetime
    add_index :docs, :deleted_at
  end
end
