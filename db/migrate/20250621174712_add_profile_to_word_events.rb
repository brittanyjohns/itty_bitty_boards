class AddProfileToWordEvents < ActiveRecord::Migration[7.1]
  def up
    add_column :word_events, :profile_id, :bigint, null: true if !column_exists?(:word_events, :profile_id)
    add_index :word_events, :profile_id unless index_exists?(:word_events, :profile_id)
  end

  def down
    remove_index :word_events, :profile_id if index_exists?(:word_events, :profile_id)
    remove_column :word_events, :profile_id if column_exists?(:word_events, :profile_id)
  end
end
