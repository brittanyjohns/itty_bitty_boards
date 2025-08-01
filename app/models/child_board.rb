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
#  created_by_id    :bigint
#
class ChildBoard < ApplicationRecord
  belongs_to :board
  belongs_to :child_account
  has_many :images, through: :board
  has_one :image_parent, through: :board
  belongs_to :created_by, class_name: "User", foreign_key: "created_by_id", optional: true

  # scope :with_artifacts, -> { includes(board: :images) }
  scope :with_artifacts, -> { includes({ board: [{ images: [:docs, :audio_files_attachments, :audio_files_blobs, :user, :category_boards] }] }, :image_parent) }

  def name
    board.name
  end

  def word_events
    WordEvent.where(board_id: board.id, child_account_id: child_account.id).order(created_at: :desc)
  end

  def display_image_url
    board.display_image_url
  end

  def other_boards
    child_account.child_boards.where.not(id: id)
  end

  def added_to_team_by
    settings["added_to_team_by"]
  end

  def team_board_id
    settings["team_board_id"]
  end

  def total_favorite_boards
    other_boards.where(favorite: true).count
  end

  def toggle_favorite
    if !favorite && total_favorite_boards >= 80
      return false
    end
    update(favorite: !favorite)
  end

  def board_type
    board.board_type
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
      added_by: created_by&.email,
      added_by_id: created_by&.id,
      board_owner_id: board.user_id,
      board_owner_name: board.user&.display_name,
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
      added_by: created_by&.email,
      layout: board.layout,
    }
  end
end
