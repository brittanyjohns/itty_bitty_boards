class CreateTeamBoards < ActiveRecord::Migration[7.1]
  def change
    create_table :team_boards do |t|
      t.belongs_to :board, null: false, foreign_key: true
      t.belongs_to :team, null: false, foreign_key: true
      t.boolean :allow_edit, default: false


      t.timestamps
    end
    add_column :team_users, :can_edit, :boolean, default: false
  end
end
