class AddDataToWordEvents < ActiveRecord::Migration[7.1]
  def up
    add_column :word_events, :data, :jsonb, default: {} if !column_exists?(:word_events, :data)
    add_index :word_events, :data, using: :gin if !index_exists?(:word_events, :data)
  end

  def down
    remove_index :word_events, :data if index_exists?(:word_events, :data)
    remove_column :word_events, :data if column_exists?(:word_events, :data)
  end
end
