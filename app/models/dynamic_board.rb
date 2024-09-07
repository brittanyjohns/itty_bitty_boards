# == Schema Information
#
# Table name: dynamic_boards
#
#  id         :bigint           not null, primary key
#  name       :string
#  board_id   :integer          not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
class DynamicBoard < ApplicationRecord
  belongs_to :board

  has_many :dynamic_board_images, dependent: :destroy
  has_many :images, through: :dynamic_board_images

  scope :with_artifacts, -> {
          includes(
            images: [
              :docs,
            # :audio_files_attachments,
            # :audio_files_blobs,
            # { user: { user_docs: :doc } },
            ],
          )
        }

  delegate :user, to: :board
  delegate :mode, to: :board
  delegate :reset_layouts, to: :board
  delegate :status, to: :board
  delegate :layout, to: :board
  delegate :number_of_columns, to: :board
  delegate :small_screen_columns, to: :board
  delegate :medium_screen_columns, to: :board
  delegate :large_screen_columns, to: :board
  delegate :audio_url, to: :board
  delegate :display_image_url, to: :board
  delegate :words, to: :board
  delegate :voice, to: :board
  delegate :position, to: :board
  delegate :description, to: :board
  delegate :predefined, to: :board
  delegate :token_limit, to: :board
  delegate :cost, to: :board

  def board_images
    dynamic_board_images
  end

  def add_image(image_id, layout = nil)
    new_board_image = nil
    if image_ids.include?(image_id.to_i)
      puts "image already added"
    else
      new_board_image = dynamic_board_images.new(image_id: image_id.to_i)
      if layout
        new_board_image.layout = layout
        new_board_image.skip_initial_layout = true
        new_board_image.save
      end
      image = Image.find(image_id)

      unless new_board_image.save
        Rails.logger.debug "new_board_image.errors: #{new_board_image.errors.full_messages}"
      end
    end
    Rails.logger.error "NO IMAGE FOUND" unless new_board_image
    new_board_image
  end

  def api_view_with_images(viewing_user = nil)
    {
      id: id,
      name: name,
      description: description,

      # number_of_columns: number_of_columns,
      # small_screen_columns: small_screen_columns,
      # medium_screen_columns: medium_screen_columns,
      # large_screen_columns: large_screen_columns,
      # status: status,
      # token_limit: token_limit,
      # cost: cost,
      # audio_url: audio_url,
      # display_image_url: display_image_url,
      # floating_words: words,
      # user_id: user_id,
      # voice: voice,
      # created_at: created_at,
      # updated_at: updated_at,
      # current_user_teams: [],
      image_count: dynamic_board_images.count,

      # current_user_teams: viewing_user ? viewing_user.teams.map(&:api_view) : [],
      # images: board_images.includes(image: [:docs, :audio_files_attachments, :audio_files_blobs]).map do |board_image|
      images: dynamic_board_images.includes(:image).map do |board_image|
        @image = board_image.image
        {
          # id: @image.id,
          # id: board_image.id,
          dynamic_board: @image.dynamic_board&.api_view,
          id: board_image.id,
          image_id: @image.id,
          board_image_id: BoardImage.find_by(image_id: @image.id)&.id,
          label: board_image.label,
          bg_color: @image.bg_class,
          next_words: board_image.next_words,
          # position: board_image.position,
          src: @image.display_image_url(viewing_user),
          audio: board_image.audio_url,
          voice: board_image.voice,
          layout: board_image.layout,
          part_of_speech: @image.part_of_speech,

          status: board_image.status,
        }
      end,
      layout: layout,
    }
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      name: name,
      layout: layout,
      audio_url: audio_url,
      position: position,
      description: description,
      predefined: predefined,
      number_of_columns: number_of_columns,
      status: status,
      token_limit: token_limit,
      cost: cost,
      display_image_url: display_image_url,
      floating_words: words,
      user_id: user_id,
      voice: voice,
    }
  end
end
