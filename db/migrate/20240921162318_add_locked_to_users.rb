class AddLockedToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :locked, :boolean, default: false if !column_exists?(:users, :locked)
    add_index :users, :locked if column_exists?(:users, :locked) && !index_exists?(:users, :locked)
  end
end
