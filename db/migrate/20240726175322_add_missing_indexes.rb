class AddMissingIndexes < ActiveRecord::Migration[7.1]
  def change
    add_index :active_storage_attachments, [:record_id, :record_type, :name]
    add_index :docs, [:documentable_id, :documentable_type, :deleted_at]
  end
end
