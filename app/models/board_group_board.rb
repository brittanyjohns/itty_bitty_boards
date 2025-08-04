# == Schema Information
#
# Table name: board_group_boards
#
#  id             :bigint           not null, primary key
#  board_group_id :bigint           not null
#  board_id       :bigint           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#
class BoardGroupBoard < ApplicationRecord
  belongs_to :board_group
  belongs_to :board

  before_save :set_initial_layout!, if: :layout_invalid?

  include BoardsHelper

  def layout
    group_layout || {}
  end

  def clean_up_layout
    new_layout = group_layout.select { |key, _| ["lg", "md", "sm", "xs", "xxs"].include?(key) }
    update!(group_layout: new_layout)
  end

  def set_initial_layout!
    self.group_layout = { "lg" => { "i" => id.to_s, "x" => grid_x("lg"), "y" => grid_y("lg"), "w" => 1, "h" => 1 },
                          "md" => { "i" => id.to_s, "x" => grid_x("md"), "y" => grid_y("md"), "w" => 1, "h" => 1 },
                          "sm" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
                          "xs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
                          "xxs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 } }
    # self.save
  end

  def grid_x(screen_size = "lg")
    return group_layout[screen_size]["x"] if group_layout[screen_size] && group_layout[screen_size]["x"]
    board_group.next_available_cell(screen_size)&.fetch("x", 0) || 0
  end

  def grid_y(screen_size = "lg")
    return group_layout[screen_size]["y"] if group_layout[screen_size] && group_layout[screen_size]["y"]
    board_group.next_available_cell(screen_size)&.fetch("y", 0) || 0
  end
end
