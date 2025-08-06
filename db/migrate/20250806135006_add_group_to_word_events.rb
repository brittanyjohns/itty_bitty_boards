class AddGroupToWordEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :word_events, :board_group_id, :bigint, null: true if !column_exists?(:word_events, :board_group_id)
    add_index :word_events, :board_group_id unless index_exists?(:word_events, :board_group_id)
    add_column :word_events, :board_image_id, :bigint, null: true if !column_exists?(:word_events, :board_image_id)
    add_index :word_events, :board_image_id unless index_exists?(:word_events, :board_image_id)
  end
end
