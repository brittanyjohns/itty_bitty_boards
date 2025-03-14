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
#  published        :boolean          default(FALSE)
#  favorite         :boolean          default(FALSE)
#
class ChildBoard < ApplicationRecord
  belongs_to :board
  belongs_to :child_account
  has_many :images, through: :board
  has_one :image_parent, through: :board

  # scope :with_artifacts, -> { includes(board: :images) }
  scope :with_artifacts, -> { includes({ board: [{ images: [:docs, :audio_files_attachments, :audio_files_blobs, :user, :category_boards] }] }, :image_parent) }

  def name
    board.name
  end

  def display_image_url
    board.display_image_url
  end

  def other_boards
    child_account.child_boards.where.not(id: id)
  end

  def total_favorite_boards
    other_boards.where(favorite: true).count
  end

  def toggle_favorite
    if !favorite && total_favorite_boards >= 8
      return false
    end
    update(favorite: !favorite)
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
      board_type: board.board_type,
      published: published,
      favorite: favorite,
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
      # images: board.images.map(&:api_view),
      images: board.board_images.map(&:api_view),
      favorite: favorite,
      board_type: board.board_type,
      published: published,

      layout: board.layout,
    }
  end
end
