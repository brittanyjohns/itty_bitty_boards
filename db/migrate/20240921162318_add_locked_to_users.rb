class AddLockedToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :locked, :boolean, default: false
    add_index :users, :locked
  end
end
