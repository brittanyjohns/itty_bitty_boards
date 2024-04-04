class AddStatusToBoard < ActiveRecord::Migration[7.1]
  def up
    add_column :boards, :status, :string, default: "pending"
    Board.update_all(status: "completed")
  end

  def down
    remove_column :boards, :status
  end
end
