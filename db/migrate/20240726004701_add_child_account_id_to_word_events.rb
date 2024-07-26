class AddChildAccountIdToWordEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :word_events, :child_account_id, :bigint
    add_index :word_events, :child_account_id
  end
end
