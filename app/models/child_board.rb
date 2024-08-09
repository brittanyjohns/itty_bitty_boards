# == Schema Information
#
# Table name: child_boards
#
#  id               :bigint           not null, primary key
#  board_id         :bigint           not null
#  child_account_id :bigint           not null
#  status           :string
#  settings         :jsonb
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#
class ChildBoard < ApplicationRecord
  belongs_to :board
  belongs_to :child_account
  has_many :images, through: :board

  scope :with_artifacts, -> { includes(board: :images) }

  def name
    board.name
  end

  def display_image_url
    board.display_image_url
  end

  def api_view
    {
      id: id,
      board_id: board_id,
      name: board.name,
      child_account_id: child_account_id,
      status: status,
      settings: settings,
      display_image_url: display_image_url,
    }
  end

  def api_view_with_images
    {
      id: id,
      board_id: board_id,
      name: board.name,
      child_account_id: child_account_id,
      status: status,
      settings: settings,
      display_image_url: display_image_url,
      images: board.images.map(&:api_view),
    }
  end
end
