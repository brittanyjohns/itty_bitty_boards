# == Schema Information
#
# Table name: boards
#
#  id                :bigint           not null, primary key
#  user_id           :bigint           not null
#  name              :string
#  parent_type       :string           not null
#  parent_id         :bigint           not null
#  description       :text
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#  cost              :integer          default(0)
#  predefined        :boolean          default(FALSE)
#  token_limit       :integer          default(0)
#  number_of_columns :integer          default(4)
#
class Board < ApplicationRecord
  belongs_to :user
  belongs_to :parent, polymorphic: true
  has_many :board_images, dependent: :destroy
  has_many :images, through: :board_images
  has_many :docs
  has_many :team_boards
  has_many :teams, through: :team_boards
  has_many :team_users, through: :teams
  has_many :users, through: :team_users
  scope :for_user, ->(user) { where(user: user) }
  scope :menus, -> { where(parent_type: "Menu") }
  scope :non_menus, -> { where.not(parent_type: "Menu") }
  scope :user_made, -> { where(parent_type: "User") }
  scope :scenarios, -> { where(parent_type: "OpenaiPrompt") }
  scope :predefined, -> { where(predefined: true) }
  scope :ai_generated, -> { where(parent_type: "OpenaiPrompt") }

  # before_save :set_number_of_columns, unless: :number_of_columns?
  before_save :set_voice, if: :voice_changed?
  before_save :set_default_voice, unless: :voice?

  # after_create_commit { broadcast_prepend_later_to :board_list, target: 'my_boards', partial: 'boards/board', locals: { board: self } }
  after_create_commit :update_board_list

  # def set_number_of_columns
  #   self.number_of_columns = 4
  # end

  def set_default_voice
    self.voice = user.settings["voice"]
  end

  def set_voice
    puts "\n\nSet Board Voice\n\n- #{voice}"
    board_images.each do |bi|
      bi.update!(voice: voice)
    end
  end

  def remaining_images
    # Image.searchable_images_for(self.user).excluding(images)
    Image.public_img.non_menu_images.excluding(images)
  end

  def display_image
    images.public_img.order(updated_at: :desc).first
  end

  def words
    if parent_type == "Menu"
      ["please","thank you", "yes", "no", "and", "help"]
    else
      ["I", "want", "to", "go", "yes", "no"]
    end
  end

  def image_docs
    images.map(&:docs).flatten
  end

  def image_docs_for_user(user)
    image_docs.select { |doc| doc.user_id == user.id }
  end

  def add_image(image_id)
    if image_ids.include?(image_id.to_i)
      puts "image already added"
    else
      new_board_image = board_images.new(image_id: image_id.to_i, voice: self.voice)
      image = Image.find(image_id)
      if image.existing_voices.include?(self.voice)
        new_board_image.voice = self.voice
      else
        image.find_or_create_audio_file_for_voice(self.voice)
      end

      unless new_board_image.save
        Rails.logger.debug "new_board_image.errors: #{new_board_image.errors.full_messages}"
      end
    end
  end

  def voice_for_image(image_id)
    board_images.find_by(image_id: image_id).voice
  end

  def add_to_cost(cost)
    self.cost = self.cost.to_f + cost.to_f
    save
  end

  def self.grid_sizes
    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10"]
  end

  def update_board_list
    puts "update_board_list"
    # broadcast_update_to(:board_list, partial: "boards/board_list", locals: { boards: user.boards }, target: "my_boards")
    broadcast_prepend_later_to :board_list, target: "my_boards_#{user.id}", partial: 'boards/board', locals: { board: self }
  end

  def render_to_board_list
    broadcast_render_to(:board_list, partial: "boards/board_list", locals: { boards: user.boards }, target: "my_boards")
  end

  def api_view_with_images
    {
      id: id,
      name: name,
      description: description,
      parent_type: parent_type,
      predefined: predefined,
      number_of_columns: number_of_columns,
      images: images.map do |image|
        {
          id: image.id,
          label: image.label,
          image_prompt: image.image_prompt,
          display_doc: image.display_image,
          src: image.display_image ? image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{image.label_param}",
          audio: image.audio_files.first&.url
        }
      end
    }
  end
end
