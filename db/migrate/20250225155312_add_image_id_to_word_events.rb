class AddImageIdToWordEvents < ActiveRecord::Migration[7.1]
  def up
    add_column :word_events, :image_id, :integer unless column_exists?(:word_events, :image_id)
    add_index :word_events, :image_id unless index_exists?(:word_events, :image_id)
  end

  def down
    remove_index :word_events, :image_id if index_exists?(:word_events, :image_id)
    remove_column :word_events, :image_id if column_exists?(:word_events, :image_id)
  end
end
