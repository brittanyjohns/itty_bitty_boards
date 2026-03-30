class DropTagsTable < ActiveRecord::Migration[7.1]
  def up
    add_column :boards, :tags, :string, array: true, default: [], null: false
    add_index :boards, :tags, using: :gin

    drop_table :board_tags if table_exists?(:board_tags)
    drop_table :tags if table_exists?(:tags)
  end

  def down
    # don't need recreate the tags and board_tags tables
  end
end
