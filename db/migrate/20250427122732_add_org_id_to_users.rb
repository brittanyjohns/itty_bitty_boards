class AddOrgIdToUsers < ActiveRecord::Migration[7.1]
  def up
    add_column :users, :organization_id, :bigint unless column_exists?(:users, :organization_id)
    add_foreign_key :users, :organizations, column: :organization_id unless foreign_key_exists?(:users, :organizations, column: :organization_id)
    add_column :teams, :organization_id, :bigint unless column_exists?(:teams, :organization_id)
    add_foreign_key :teams, :organizations, column: :organization_id unless foreign_key_exists?(:teams, :organizations, column: :organization_id)
  end

  def down
    remove_foreign_key :users, column: :organization_id if foreign_key_exists?(:users, :organizations, column: :organization_id)
    remove_column :users, :organization_id if column_exists?(:users, :organization_id)
    remove_foreign_key :teams, column: :organization_id if foreign_key_exists?(:teams, :organizations, column: :organization_id)
    remove_column :teams, :organization_id if column_exists?(:teams, :organization_id)
  end
end
