class AddUserSettings < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :settings, :jsonb, default: {}
    add_column :users, :base_words, :string, array: true, default: []
  end
end
