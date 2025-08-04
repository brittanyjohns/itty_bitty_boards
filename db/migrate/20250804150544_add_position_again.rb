class AddPositionAgain < ActiveRecord::Migration[7.1]
  def change
    add_column :board_group_boards, :position, :integer, default: 0, null: false unless column_exists?(:board_group_boards, :position)
    add_column :board_group_boards, :group_layout, :jsonb, default: {}, null: false unless column_exists?(:board_group_boards, :group_layout)

    BoardGroup.reset_column_information
    BoardGroup.find_each do |group|
      group.board_group_boards.each_with_index do |bgb, index|
        bgb.update(position: index) unless bgb.position && bgb.position == index
      end
    end
  end
end
