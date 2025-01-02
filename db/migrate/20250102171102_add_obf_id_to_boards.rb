class AddObfIdToBoards < ActiveRecord::Migration[7.1]
  def change
    add_column :boards, :obf_id, :string
    add_index :boards, :obf_id
  end
end
