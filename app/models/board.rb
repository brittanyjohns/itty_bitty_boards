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
#  layout                :jsonb
#  position              :integer
#  audio_url             :string
#  bg_color              :string
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
  has_many :board_group_boards, dependent: :destroy
  has_many :board_groups, through: :board_group_boards
  has_many :child_boards, dependent: :destroy

  has_many :dynamic_boards

  include BoardsHelper

  scope :for_user, ->(user) { where(user: user) }
  scope :menus, -> { where(parent_type: "Menu") }
  scope :non_menus, -> { where.not(parent_type: "Menu") }
  scope :user_made, -> { where(parent_type: "User") }
  scope :scenarios, -> { where(parent_type: "OpenaiPrompt") }
  scope :user_made_with_scenarios, -> { where(parent_type: ["User", "OpenaiPrompt", "PredefinedResource"]) }
  scope :user_made_with_scenarios_and_menus, -> { where(parent_type: ["User", "OpenaiPrompt", "Menu"]) }
  scope :predictive, -> { where(parent_type: "PredefinedResource") }
  scope :predefined, -> { where(predefined: true) }
  scope :ai_generated, -> { where(parent_type: "OpenaiPrompt") }
  scope :with_less_than_10_images, -> { joins(:images).group("boards.id").having("count(images.id) < 10") }
  scope :with_less_than_x_images, ->(x) { joins(:images).group("boards.id").having("count(images.id) < ?", x) }
  scope :without_images, -> { left_outer_joins(:images).where(images: { id: nil }) }

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

  before_save :set_voice, if: :voice_changed?
  before_save :set_default_voice, unless: :voice?

  # before_save :rearrange_images, if: :number_of_columns_changed?

  before_save :set_status
  before_create :set_number_of_columns
  before_destroy :delete_menu, if: :parent_type_menu?
  after_initialize :set_screen_sizes, unless: :all_validate_screen_sizes?
  after_initialize :set_initial_layout, if: :layout_empty?

  def layout_empty?
    layout.blank?
  end

  def set_initial_layout
    self.layout = { "lg" => [], "md" => [], "sm" => [] }
  end

  validates :name, presence: true

  def all_validate_screen_sizes?
    if small_screen_columns&.zero? || medium_screen_columns&.zero? || large_screen_columns&.zero?
      errors.add(:screen_sizes, "can't be zero")
      return false
    end
    true
  end

  def set_screen_sizes
    self.small_screen_columns = 3
    self.medium_screen_columns = 8
    self.large_screen_columns = 12
  end

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
    predictive_default.calculate_grid_layout
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

  def self.create_base_board
    words = ["I", "you", "he", "she", "it", "we", "they", "that", "this", "the", "a", "is", "can", "will", "do", "don't", "go", "want"]
    base_board = self.with_artifacts.find_or_create_by(name: "Base", user_id: User.admin.first.id, parent: PredefinedResource.find_or_create_by(name: "Default", resource_type: "Board"), predefined: true)
    base_board.images.destroy_all
    words.each do |word|
      image = Image.public_img.find_or_create_by(label: word)
      base_board.add_image(image.id)
    end
    base_board.reset_layouts
  end

  def set_number_of_columns
    return unless number_of_columns.nil?
    self.number_of_columns = self.large_screen_columns
  end

  def set_status
    puts "Setting status"
    puts "Parent type: #{parent_type}"
    if parent_type == "User" || predefined || parent_type == "BoardImage"
      self.status = "complete"
    else
      if has_generating_images?
        self.status = "generating"
      else
        self.status = "complete"
      end
    end
  end

  def rearrange_images(layout = nil, screen_size = "lg")
    ActiveRecord::Base.logger.silence do
      layout ||= calculate_grid_layout_for_screen_size(screen_size)
      update_grid_layout(layout, screen_size)
    end
  end

  def has_generating_images?
    board_images.any? { |bi| bi.status == "generating" }
  end

  def pending_images
    board_images.where(status: ["pending", "generating"])
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

  # def position_all_board_images
  #   ActiveRecord::Base.logger.silence do
  #     board_images.order(:position).each_with_index do |bi, index|
  #       unless bi.position && bi.position == index
  #         bi.update!(position: index)
  #       end
  #     end
  #   end
  # end

  def self.create_predictive_default
    predefined_resource = PredefinedResource.find_or_create_by name: "Predictive Default", resource_type: "Board"
    admin_user = User.admin.first
    Board.with_artifacts.find_or_create_by!(name: "Predictive Default", user_id: admin_user.id, parent: predefined_resource)
  end

  def set_default_voice
    self.voice = user.settings["voice"]["name"] || "echo"
  end

  def set_voice
    puts "Setting voice"
    board_images.includes(:image).each do |bi|
      bi.create_voice_audio(voice)
    end
  end

  def remaining_images
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

  def create_audio_from_text(text = nil, voice = "echo")
    return if voice == "none" || Rails.env.test?
    text = text || self.name
    response = OpenAiClient.new(open_ai_opts).create_audio_from_text(text, voice)
    if response
      File.open("output.aac", "wb") { |f| f.write(response) }
      audio_file = File.open("output.aac")
      save_audio_file(audio_file, voice, text)
      file_exists = File.exist?("output.aac")
      File.delete("output.aac") if file_exists
    else
      Rails.logger.error "**** ERROR **** \nDid not receive valid response.\n #{response&.inspect}"
    end
  end

  def save_audio_file(audio_file, voice, text)
    raw_text = text || self.name
    text = raw_text.downcase.gsub(" ", "_")
    self.audio_files.attach(io: audio_file, filename: "#{text}_#{voice}.aac")
  end

  def rename_audio_files
    board_images.includes(:image).each do |bi|
      bi.image.destroy_audio_files_without_voices
      bi.image.rename_audio_files
    end
  end

  def image_docs
    images.map(&:docs).flatten
  end

  def image_docs_for_user(user = nil)
    user ||= self.user
    image_docs.select { |doc| doc.user_id == user.id }
  end

  def create_audio_files_for_images
    board_images.each do |bi|
      bi.create_voice_audio
    end
  end

  def self.create_audio_files_for_images(scope = nil)
    scope ||= self
    scope.
      includes(:board_images).find_each do |board|
      board.board_images.each do |bi|
        bi.create_voice_audio
      end
    end
  end

  def remove_image(image_id)
    board_images.find_by(image_id: image_id).destroy
  end

  def add_images(image_ids)
    image_ids.each do |image_id|
      add_image(image_id)
    end
  end

  def add_image(image_id, layout = nil)
    new_board_image = nil
    if image_ids.include?(image_id.to_i)
      puts "image already added"
    else
      new_board_image = board_images.new(image_id: image_id.to_i, voice: self.voice)
      if layout
        new_board_image.layout = layout
        new_board_image.skip_initial_layout = true
        new_board_image.save
      end
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
    Rails.logger.error "NO IMAGE FOUND" unless new_board_image
    new_board_image
  end

  def clone_with_images(cloned_user_id, new_name)
    if new_name.blank?
      new_name = name + " copy"
    end
    @source = self
    cloned_user = User.find(cloned_user_id)
    unless cloned_user
      Rails.logger.debug "User not found: #{cloned_user_id} - defaulting to admin"
      cloned_user_id = User::DEFAULT_ADMIN
      cloned_user = User.find(cloned_user_id)
      if !cloned_user
        Rails.logger.debug "Default admin user not found: #{cloned_user_id}"
        return
      end
    end
    @images = @source.images
    @board_images = @source.board_images
    @layouts = @board_images.pluck(:image_id, :layout)

    @cloned_board = @source.dup
    @cloned_board.user_id = cloned_user_id
    @cloned_board.name = new_name
    @cloned_board.save
    @images.each do |image|
      layout = @layouts.find { |l| l[0] == image.id }&.second
      puts "layout: #{layout}"
      @cloned_board.add_image(image.id, layout)
    end
    if @cloned_board.save
      @cloned_board
    else
      Rails.logger.debug "Error cloning board: #{@cloned_board}"
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
      has_generating_images: has_generating_images?,
      current_user_teams: [],
      # current_user_teams: viewing_user ? viewing_user.teams.map(&:api_view) : [],
      # images: board_images.includes(image: [:docs, :audio_files_attachments, :audio_files_blobs]).map do |board_image|
      # images: board_images.includes(image: :docs).map do |board_image|
      #   @image = board_image.image
      #   {
      #     id: @image.id,
      #     # id: board_image.id,
      #     mode: board_image.mode,
      #     dynamic_board: board_image.dynamic_board&.api_view,
      #     board_image_id: board_image.id,
      #     label: board_image.label,
      #     image_prompt: board_image.image_prompt,
      #     bg_color: @image.bg_class,
      #     text_color: board_image.text_color,
      #     next_words: board_image.next_words,
      #     position: board_image.position,
      #     src: @image.display_image_url(viewing_user),
      #     audio: board_image.audio_url,
      #     voice: board_image.voice,
      #     layout: board_image.layout,
      #     added_at: board_image.added_at,
      #     image_last_added_at: board_image.image_last_added_at,
      #     part_of_speech: @image.part_of_speech,

      #     status: board_image.status,
      #   }
      # end,
      # images: board_images.includes(:image).map(&:api_view),
      images: board_images.includes(:image).map do |board_image|
        {
          id: board_image.id,
          layout: board_image.layout,
          label: board_image.label,
          src: board_image.image.display_image_url(viewing_user),
          audio: board_image.audio_url,
        }
      end,
      layout: layout,
    }
  end

  def mode
    dynamic_board = DynamicBoard.joins(:board).find_by(boards: { user_id: user_id })
    dynamic_board ? "dynamic" : "static"
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

  # SCREEN_SIZES = %w[sm md lg].freeze

  # def print_grid_layout_for_screen_size(screen_size)
  #   layout_to_set = layout[screen_size] || {}
  #   board_images.order(:position).each_with_index do |bi, i|
  #     if bi.layout[screen_size]
  #       layout_to_set[bi.id] = bi.layout[screen_size]
  #     end
  #   end
  #   layout_to_set = layout_to_set.compact # Remove nil values
  #   layout_to_set
  # end

  # def print_grid_layout
  #   layout_to_set = layout || {}
  #   SCREEN_SIZES.each do |screen_size|
  #     layout_to_set[screen_size] = print_grid_layout_for_screen_size(screen_size)
  #   end
  #   layout_to_set
  # end

  # def calculate_grid_layout_for_screen_size(screen_size, reset_layouts = false)
  #   case screen_size
  #   when "sm"
  #     number_of_columns = self.small_screen_columns || 1
  #   when "md"
  #     number_of_columns = self.medium_screen_columns || 8
  #   when "lg"
  #     number_of_columns = self.large_screen_columns || 12
  #   else
  #     number_of_columns = self.large_screen_columns || 12
  #   end

  #   layout_to_set = {} # Initialize as a hash

  #   position_all_board_images
  #   row_count = 0
  #   bi_count = board_images.count
  #   rows = (bi_count / number_of_columns.to_f).ceil
  #   ActiveRecord::Base.logger.silence do
  #     board_images.order(:position).each_slice(number_of_columns) do |row|
  #       row.each_with_index do |bi, index|
  #         new_layout = {}
  #         if bi.layout[screen_size] && reset_layouts == false
  #           new_layout = bi.layout[screen_size]
  #         else
  #           new_layout = { "i" => bi.id.to_s, "x" => index, "y" => row_count, "w" => 1, "h" => 1 }
  #         end

  #         bi.layout[screen_size] = new_layout
  #         bi.skip_create_voice_audio = true
  #         bi.save
  #         bi.clean_up_layout
  #         layout_to_set[bi.id] = new_layout # Treat as a hash
  #       end
  #       row_count += 1
  #     end
  #   end
  #   Rails.logger.debug "calculate_grid_layout_for_screen_size: #{layout_to_set}"

  #   self.layout[screen_size] = layout_to_set.values # Convert back to an array if needed
  #   self.board_images.reset
  #   self.save!
  # end

  # def set_layouts_for_screen_sizes
  #   calculate_grid_layout_for_screen_size("sm", true)
  #   calculate_grid_layout_for_screen_size("md", true)
  #   calculate_grid_layout_for_screen_size("lg", true)
  # end

  # def reset_layouts
  #   self.layout = {}
  #   self.set_layouts_for_screen_sizes
  #   self.save!
  # end

  def update_grid_layout(layout_to_set, screen_size)
    Rails.logger.debug "update_grid_layout: #{layout_to_set}"
    layout_for_screen_size = self.layout[screen_size] || []
    unless layout_to_set.is_a?(Array)
      Rails.logger.debug "layout_to_set is not an array"
      return
    end
    layout_to_set.each do |layout_item|
      id_key = layout_item[:i]
      layout_hash = layout_item.with_indifferent_access
      id_key = layout_hash[:i] || layout_hash["i"]
      bi = board_images.find(id_key) rescue nil
      Rails.logger.debug "BoardImage not found for id: #{id_key}" if bi.nil?
      bi = board_images.find_by(image_id: id_key) if bi.nil?
      bi.layout[screen_size] = layout_hash
      bi.clean_up_layout
      bi.save!
    end
    self.layout[screen_size] = layout_to_set
    self.board_images.reset
    self.save!
  end

  def next_grid_cell
    puts "Next grid cell"
    x = board_images.pluck(:layout).map { |l| l[:x] }.max
    y = board_images.pluck(:layout).map { |l| l[:y] }.max
    puts "x: #{x}, y: #{y}"
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
          audio: image.audio_url,
        }
      end,
    }
  end
end
