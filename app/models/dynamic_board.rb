# == Schema Information
#
# Table name: dynamic_boards
#
#  id                    :bigint           not null, primary key
#  name                  :string
#  user_id               :integer
#  parent_id             :integer
#  parent_type           :string
#  description           :text
#  cost                  :integer          default(0)
#  predefined            :boolean          default(FALSE)
#  token_limit           :integer          default(0)
#  voice                 :string           default("echo")
#  status                :string           default("pending")
#  number_of_columns     :integer          default(6)
#  small_screen_columns  :integer          default(3)
#  medium_screen_columns :integer          default(8)
#  large_screen_columns  :integer          default(12)
#  display_image_url     :string
#  layout                :jsonb
#  position              :integer
#  audio_url             :string
#  bg_color              :string
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#
class DynamicBoard < ApplicationRecord
  belongs_to :user, optional: true
  belongs_to :parent, polymorphic: true, optional: true

  has_many :dynamic_board_images, dependent: :destroy
  has_many :images, through: :dynamic_board_images

  include BoardsHelper

  def words
    parent.next_words
  end

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
      parent_type: parent_type,
      parent_id: parent_id,
      parent_description: parent_type === "User" ? "User" : parent.description,
      parent_prompt: parent_type === "OpenaiPrompt" ? parent.prompt_text : nil,
      predefined: predefined,
      number_of_columns: number_of_columns,
      small_screen_columns: small_screen_columns,
      medium_screen_columns: medium_screen_columns,
      large_screen_columns: large_screen_columns,
      status: status,
      token_limit: token_limit,
      cost: cost,
      audio_url: audio_url,
      display_image_url: display_image_url,
      floating_words: words,
      user_id: user_id,
      voice: voice,
      created_at: created_at,
      updated_at: updated_at,
      current_user_teams: [],
      image_count: dynamic_board_images.count,
      # current_user_teams: viewing_user ? viewing_user.teams.map(&:api_view) : [],
      # images: board_images.includes(image: [:docs, :audio_files_attachments, :audio_files_blobs]).map do |board_image|
      images: dynamic_board_images.includes(image: :docs).map do |board_image|
        @image = board_image.image
        {
          id: @image.id,
          # id: board_image.id,
          mode: parent.mode,
          dynamic_board: board_image.dynamic_board&.api_view,
          board_image_id: board_image.id,
          label: board_image.label,
          bg_color: @image.bg_class,
          next_words: board_image.next_words,
          position: board_image.position,
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
      parent_type: parent_type,
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
