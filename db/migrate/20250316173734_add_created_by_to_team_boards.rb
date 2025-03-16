class AddCreatedByToTeamBoards < ActiveRecord::Migration[7.1]
  def up
    add_column :team_boards, :created_by_id, :bigint if !column_exists?(:team_boards, :created_by_id)
    add_foreign_key :team_boards, :users, column: :created_by_id if !foreign_key_exists?(:team_boards, :users, column: :created_by_id)
    add_column :child_boards, :created_by_id, :bigint if !column_exists?(:child_boards, :created_by_id)
    add_foreign_key :child_boards, :users, column: :created_by_id if !foreign_key_exists?(:child_boards, :users, column: :created_by_id)
  end

  def down
    remove_foreign_key :team_boards, column: :created_by_id if foreign_key_exists?(:team_boards, :users, column: :created_by_id)
    remove_column :team_boards, :created_by_id if column_exists?(:team_boards, :created_by_id)
    remove_foreign_key :child_accounts, column: :created_by_id if foreign_key_exists?(:child_accounts, :users, column: :created_by_id)
    remove_column :child_accounts, :created_by_id if column_exists?(:child_accounts, :created_by_id)
    remove_foreign_key :child_boards, column: :created_by_id if foreign_key_exists?(:child_boards, :users, column: :created_by_id)
    remove_column :child_boards, :created_by_id if column_exists?(:child_boards, :created_by_id)
  end
end
