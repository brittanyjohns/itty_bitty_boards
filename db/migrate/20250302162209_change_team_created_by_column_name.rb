class ChangeTeamCreatedByColumnName < ActiveRecord::Migration[7.1]
  def change
    rename_column :teams, :created_by, :created_by_id
  end
end
