# == Schema Information
#
# Table name: boards
#
#  id                    :bigint           not null, primary key
#  user_id               :bigint           not null
#  name                  :string
#  parent_type           :string           not null
#  parent_id             :bigint           not null
#  description           :text
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  cost                  :integer          default(0)
#  predefined            :boolean          default(FALSE)
#  token_limit           :integer          default(0)
#  voice                 :string
#  status                :string           default("pending")
#  number_of_columns     :integer          default(6)
#  small_screen_columns  :integer          default(3)
#  medium_screen_columns :integer          default(8)
#  large_screen_columns  :integer          default(12)
#  display_image_url     :string
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
  scope :user_made_with_scenarios, -> { where(parent_type: ["User", "OpenaiPrompt"]) }
  scope :user_made_with_scenarios_and_menus, -> { where(parent_type: ["User", "OpenaiPrompt", "Menu"]) }
  scope :predictive, -> { where(parent_type: "PredefinedResource") }
  scope :predefined, -> { where(predefined: true) }
  scope :ai_generated, -> { where(parent_type: "OpenaiPrompt") }
  scope :with_less_than_10_images, -> { joins(:images).group("boards.id").having("count(images.id) < 10") }
  scope :with_less_than_x_images, ->(x) { joins(:images).group("boards.id").having("count(images.id) < ?", x) }
  scope :without_images, -> { left_outer_joins(:images).where(images: { id: nil }) }

  scope :with_artifacts, -> {
          includes({
            images: [
              { docs: :image_attachment },
              :audio_files_attachments,
            ],
            user: { user_docs: [{ doc: [{ image_attachment: :blob }] }] },
          })
        }

  before_save :set_voice, if: :voice_changed?
  before_save :set_default_voice, unless: :voice?

  before_save :rearrange_images, if: :number_of_columns_changed?
  # before_save :set_display_image, if: :display_image_url.nil?

  after_touch :set_status
  before_create :set_number_of_columns
  before_destroy :delete_menu, if: :parent_type_menu?

  validates :name, presence: true

  def parent_type_menu?
    parent_type == "Menu"
  end

  def delete_menu
    begin
      parent.destroy!
    rescue => e
      puts "Error deleting parent: #{e.inspect}"
    end
  end

  def self.common_words
    ["Yes", "No", "Please", "Thank you", "Help", "More", "I want", "Eat", "Drink", "Bathroom", "Pain", "Stop",
     "Go", "Like", "Don't", "Play", "Finished", "Hungry", "Thirsty", "Tired", "Sad",
     "Happy", "Mom", "Dad", "Friend", "Hot", "Cold", "Where", "Come here", "I need", "Sorry", "Goodbye",
     "Hello", "What", "Who", "How", "When", "Why", "Look", "Listen", "Read",
     "Write", "Open", "Close", "Turn on", "Turn off", "Up", "Down", "In", "Out"]
  end

  def self.update_predictive(words = nil)
    words ||= common_words
    predictive_default = self.predictive_default
    predictive_default.images.destroy_all
    words.each do |word|
      image = Image.public_img.find_or_create_by(label: word)
      predictive_default.add_image(image.id)
      image.save!
    end
    predictive_default.calucate_grid_layout
    predictive_default.save!
  end

  def self.create_predictive
    words = common_words
    predictive_default = self.predictive_default
    predictive_default.images.destroy_all
    words.each do |word|
      image = Image.find_or_create_by(label: word, user_id: predictive_default.user_id)
      predictive_default.images << image
    end
  end

  def set_number_of_columns
    return unless number_of_columns.nil?
    self.number_of_columns = self.large_screen_columns
  end

  def set_status
    if parent_type == "User" || predefined
      self.status = "complete"
    else
      puts "board status: #{status} - if has_generating_images? #{has_generating_images?}"
      if has_generating_images?
        self.status = "generating"
      else
        self.status = "complete"
      end
    end
    self.save!
    puts "board status: #{status}"
  end

  def rearrange_images(layout = nil)
    ActiveRecord::Base.logger.silence do
      layout ||= calucate_grid_layout
      update_grid_layout(layout)
    end
  end

  def has_generating_images?
    board_images.any? { |bi| bi.status == "generating" }
  end

  def predictive?
    parent_type == "PredefinedResource" && parent.name == "Next"
  end

  def self.predictive_default
    self.with_artifacts.where(parent_type: "PredefinedResource", name: "Predictive Default").first
  end

  def self.position_all_board_images
    includes(:board_images).find_each do |board|
      board.board_images.each_with_index do |bi, index|
        bi.update!(position: index)
      end
    end
  end

  def position_all_board_images
    ActiveRecord::Base.logger.silence do
      board_images.order(:position).each_with_index do |bi, index|
        unless bi.position && bi.position == index
          bi.update!(position: index)
        end
      end
    end
  end

  def self.create_predictive_default
    predefined_resource = PredefinedResource.find_or_create_by name: "Predictive Default", resource_type: "Board"
    admin_user = User.admin.first
    Board.find_or_create_by!(name: "Predictive Default", user_id: admin_user.id, parent: predefined_resource)
  end

  def set_default_voice
    self.voice = user.settings["voice"]["name"] || "echo"
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

  def set_display_image
    new_doc = image_docs.first
    self.display_image_url = new_doc.display_url if new_doc
    # self.save!
  end

  def create_audio_for_words
    words.each do |word|
      self.create_audio_from_text(word)
    end
  end

  def create_audio_from_text(text, voice = "echo")
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

  def image_docs_for_user(user = nil)
    user ||= self.user
    image_docs.select { |doc| doc.user_id == user.id }
  end

  def add_image(image_id)
    new_board_image = nil
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
    new_board_image
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

  def api_view_with_images(viewing_user = nil)
    {
      id: id,
      name: name,
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
      created_at: created_at,
      updated_at: updated_at,
      has_generating_images: has_generating_images?,
      current_user_teams: viewing_user ? viewing_user.teams.map(&:api_view) : [],
      images: board_images.includes(:image).map do |board_image|
        {
          id: board_image.image.id,
          label: board_image.image.label,
          image_prompt: board_image.image.image_prompt,
          bg_color: board_image.image.bg_class,
          text_color: board_image.image.text_color,
          next_words: board_image.image.next_words,
          position: board_image.position,
          # display_doc: board_image.image.display_image,
          src: board_image.image.display_image_url(viewing_user),
          # src: board_image.image.display_image ? board_image.image.display_image.url : "https://via.placeholder.com/300x300.png?text=#{board_image.image.label_param}",
          audio: board_image.image.default_audio_url,
          layout: board_image.layout,
          added_at: board_image.added_at,
          image_last_added_at: board_image.image_last_added_at,
          status: board_image.status,
        }
      end,
    }
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      name: name,
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

  def calucate_grid_layout
    position_all_board_images
    grid_layout = []
    row_count = 0
    bi_count = board_images.count
    number_of_columns = self.number_of_columns || self.large_screen_columns
    rows = (bi_count / number_of_columns.to_f).ceil
    ActiveRecord::Base.logger.silence do
      board_images.order(:position).each_slice(number_of_columns) do |row|
        row.each_with_index do |bi, index|
          new_layout = { i: bi.id, x: index, y: row_count, w: 1, h: 1 }
          bi.update!(layout: new_layout)
          grid_layout << new_layout
        end
        row_count += 1
      end
    end
    grid_layout
  end

  def update_grid_layout(layout)
    layout.each do |layout_item|
      bi = board_images.find(layout_item[:i])
      bi.update!(layout: layout_item)
    end
  end

  def next_grid_cell
    x = board_images.pluck(:layout).map { |l| l[:x] }.max
    y = board_images.pluck(:layout).map { |l| l[:y] }.max
    x = 0 if x.nil?
    y = 0 if y.nil?
    x += 1
    y += 1 if x >= number_of_columns
    { x: x, y: y }
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
