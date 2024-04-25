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
  has_many :team_boards, dependent: :destroy
  has_many :teams, through: :team_boards
  has_many :team_users, through: :teams
  has_many :users, through: :team_users
  has_many_attached :audio_files
  scope :for_user, ->(user) { where(user: user) }
  scope :menus, -> { where(parent_type: "Menu") }
  scope :non_menus, -> { where.not(parent_type: "Menu") }
  scope :user_made, -> { where(parent_type: "User") }
  scope :scenarios, -> { where(parent_type: "OpenaiPrompt") }
  scope :predictive, -> { where(parent_type: "PredefinedResource") }
  scope :predefined, -> { where(predefined: true) }
  scope :ai_generated, -> { where(parent_type: "OpenaiPrompt") }
  scope :with_less_than_10_images, -> { joins(:images).group("boards.id").having("count(images.id) < 10") }
  scope :with_less_than_x_images, ->(x) { joins(:images).group("boards.id").having("count(images.id) < ?", x) }
  scope :without_images, -> { left_outer_joins(:images).where(images: { id: nil }) }
  # before_save :set_number_of_columns, unless: :number_of_columns?
  before_save :set_voice, if: :voice_changed?
  before_save :set_default_voice, unless: :voice?

  after_save :calucate_grid_layout, if: :number_of_columns_changed?

  # after_create_commit { broadcast_prepend_later_to :board_list, target: 'my_boards', partial: 'boards/board', locals: { board: self } }
  # after_create_commit :update_board_list

  before_save :set_status
  before_create :set_number_of_columns

  def self.ransackable_attributes(auth_object = nil)
    ["cost", "created_at", "description", "id", "id_value", "name", "number_of_columns", "parent_id", "parent_type", "predefined", "status", "token_limit", "updated_at", "user_id", "voice"]
  end

  def set_number_of_columns
    self.number_of_columns = 4
  end

  def set_status
    return unless status.nil? || status == "pending"
    if parent_type == "User" || predefined
      self.status = "complete"
    else
      puts "board status: #{status}"
    end
  end

  def has_generating_images?
    image_statuses = images.map(&:status)
    image_statuses.include?("generating")
  end

  def predictive?
    parent_type == "PredefinedResource" && parent.name == "Next"
  end

  def self.predictive_default
    self.where(parent_type: "PredefinedResource", name: "Predictive Default").first
  end

  def self.position_all_board_images
    all.each do |board|
      board.board_images.each_with_index do |bi, index|
        bi.update!(position: index)
      end
    end
  end

  def position_all_board_images
    board_images.order(:position).each_with_index do |bi, index|
      bi.update!(position: index)
    end
  end

  def self.create_predictive_default
    predefined_resource = PredefinedResource.find_or_create_by name: "Predictive Default", resource_type: "Board"
    admin_user = User.admin.first
    puts "Predefined resource created: #{predefined_resource.name} admin_user: #{admin_user.email}"
    predictive_default_board = Board.find_or_create_by!(name: "Predictive Default", user_id: admin_user.id, parent: predefined_resource)
    puts "Predictive Default Board created: #{predictive_default_board.name}"
    predictive_default_board
  end

  def set_default_voice
    puts "\n\nSet Default Voice\n\n"
    self.voice = user.settings["voice"]["name"] || "alloy"
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
      ["please", "thank you", "yes", "no", "and", "help"]
    else
      ["I", "want", "to", "go", "yes", "no"]
    end
  end

  def open_ai_opts
    {}
  end

  def create_audio_for_words
    words.each do |word|
      self.create_audio_from_text(word)
    end
  end

  def create_audio_from_text(text, voice = "alloy")
    response = OpenAiClient.new(open_ai_opts).create_audio_from_text(text, voice)
    if response
      audio_file = File.open("output.aac", "wb") { |f| f.write(response) }
      save_audio_file(audio_file, voice, text)
      File.delete("output.aac") if File.exist?("output.aac")
    else
      Rails.logger.error "**** ERROR **** \nDid not receive valid response.\n #{response&.inspect}"
    end
  end

  def save_audio_file(audio_file, voice, text)
    self.audio_files.attach(io: audio_file, filename: "#{self.id}_#{voice}_#{text}.aac")
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
    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20"]
  end

  def update_board_list
    # broadcast_update_to(:board_list, partial: "boards/board_list", locals: { boards: user.boards }, target: "my_boards")
    broadcast_prepend_later_to :board_list, target: "my_boards_#{user.id}", partial: "boards/board", locals: { board: self }
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
      status: status,
      floating_words: words,
      user_id: user_id,
      voice: voice,
      images: board_images.map do |board_image|
        {
          id: board_image.image.id,
          label: board_image.image.label,
          image_prompt: board_image.image.image_prompt,
          bg_color: board_image.image.bg_class,
          text_color: board_image.image.text_color,
          next_words: board_image.image.next_words,
          position: board_image.position,
          display_doc: board_image.image.display_image,
          src: board_image.image.display_image ? board_image.image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{board_image.image.label_param}",
          audio: board_image.image.audio_files.first&.url,
          layout: board_image.layout,
        }
      end,
    }
  end

  def calucate_grid_layout
    position_all_board_images
    puts "\n\nCalucate Grid Layout\n\n"
    grid_layout = []
    row_count = 0
    bi_count = board_images.count
    rows = (bi_count / number_of_columns.to_f).ceil
    board_images.includes(:image).order(:position).each_slice(rows) do |row|
      puts "row: #{row.count}"
      row.each_with_index do |bi, index|
        new_layout = { i: bi.id, x: index, y: row_count, w: 1, h: 1}
        puts "id: #{bi.id} x: #{index} y: #{row_count} -- bi: #{bi.label} -- position: #{bi.position}"
        bi.update!(layout: new_layout)
        bi.reload
        puts "layout: #{bi.layout}"
      end
      row_count += 1

    end
    grid_layout
  end


  def api_view_with_predictive_images
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
          bg_color: image.bg_class,
          text_color: image.text_color,
          next_words: image.next_words,
          display_doc: image.display_image,
          src: image.display_image ? image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{image.label_param}",
          audio: image.audio_files.first&.url,
        }
      end,
    }
  end
end
