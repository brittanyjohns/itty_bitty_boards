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
#  margin_settings       :jsonb
#  settings              :jsonb
#  category              :string
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

  attr_accessor :skip_create_voice_audio

  include UtilHelper

  include PgSearch::Model
  pg_search_scope :search_by_name,
                  against: :name,
                  using: {
                    tsearch: { prefix: true },
                  }

  scope :for_user, ->(user) { where(user: user) }
  scope :menus, -> { where(parent_type: "Menu") }
  scope :non_menus, -> { where.not(parent_type: "Menu") }
  scope :user_made, -> { where(parent_type: "User") }
  scope :scenarios, -> { where(parent_type: "OpenaiPrompt") }
  scope :user_made_with_scenarios, -> { where(parent_type: ["User", "OpenaiPrompt"], predefined: false) }
  scope :user_made_with_scenarios_and_menus, -> { where(parent_type: ["User", "OpenaiPrompt", "Menu", "PredefinedResource"], predefined: false) }
  scope :predefined, -> { where(predefined: true) }
  scope :ai_generated, -> { where(parent_type: "OpenaiPrompt") }
  scope :with_less_than_10_images, -> { joins(:images).group("boards.id").having("count(images.id) < 10") }
  scope :with_less_than_x_images, ->(x) { joins(:images).group("boards.id").having("count(images.id) < ?", x) }
  scope :without_images, -> { left_outer_joins(:images).where(images: { id: nil }) }

  scope :predictive, -> { where(parent_type: ["Image", "PredefinedResource"]) }

  scope :created_this_week, -> { where("created_at > ?", 1.week.ago) }
  scope :created_before_this_week, -> { where("created_at < ?", 11.days.ago) }

  scope :featured, -> { where(category: ["featured", "popular"], predefined: true) }
  scope :popular, -> { where(category: "popular", predefined: true) }
  scope :general, -> { where(category: "general", predefined: true) }
  scope :seasonal, -> { where(category: "seasonal", predefined: true) }
  scope :routines, -> { where(category: "routines", predefined: true) }
  scope :emotions, -> { where(category: "emotions", predefined: true) }
  scope :actions, -> { where(category: "actions", predefined: true) }
  scope :animals, -> { where(category: "animals", predefined: true) }
  scope :food, -> { where(category: "food", predefined: true) }
  scope :people, -> { where(category: "people", predefined: true) }
  scope :places, -> { where(category: "places", predefined: true) }
  scope :things, -> { where(category: "things", predefined: true) }
  scope :colors, -> { where(category: "colors", predefined: true) }
  scope :shapes, -> { where(category: "shapes", predefined: true) }
  scope :numbers, -> { where(category: "numbers", predefined: true) }
  scope :letters, -> { where(category: "letters", predefined: true) }
  scope :preset, -> { where(predefined: true) }
  scope :welcome, -> { where(category: "welcome", predefined: true) }

  SAFE_FILTERS = %w[all welcome preset featured popular general seasonal routines emotions actions animals food people places things colors shapes numbers letters].freeze

  scope :with_artifacts, -> { includes({ board_images: { image: [:docs, :audio_files_attachments, :audio_files_blobs] } }) }

  include ImageHelper

  before_save :set_voice, if: :voice_changed?
  before_save :set_default_voice, unless: :voice?
  before_save :update_display_image, unless: :display_image_url?

  # before_save :rearrange_images, if: :number_of_columns_changed?

  before_save :set_display_margin_settings, unless: :margin_settings_valid_for_all_screen_sizes?

  after_touch :set_status
  before_create :set_number_of_columns
  before_destroy :delete_menu, if: :parent_type_menu?
  after_initialize :set_screen_sizes, unless: :all_validate_screen_sizes?
  after_initialize :set_initial_layout, if: :layout_empty?

  def set_initial_layout
    self.layout = { "lg" => [], "md" => [], "sm" => [] }
  end

  def layout_empty?
    layout.blank?
  end

  validates :name, presence: true

  def all_validate_screen_sizes?
    if small_screen_columns&.zero? || medium_screen_columns&.zero? || large_screen_columns&.zero?
      errors.add(:screen_sizes, "can't be zero")
      return false
    end
    true
  end

  def clean_up_scenarios
    Scenario.where(board_id: id).destroy_all
  end

  def label_for_filename
    name.downcase.gsub(" ", "_")
  end

  def default_audio_url(audio_file = nil)
    audio_file ||= audio_files.first
    audio_blob = audio_file&.blob

    cdn_url = "#{ENV["CDN_HOST"]}/#{audio_blob.key}" if audio_blob

    audio_blob ? cdn_url : nil
  end

  def create_voice_audio
    return if @skip_create_voice_audio
    puts "Creating voice audio for board: #{name} - #{voice}"
    # return Rails.env.test?
    label_voice = "#{label_for_filename}_#{voice}"
    filename = "#{label_voice}.aac"
    puts "Filename: #{filename}"
    # already_has_audio_file = existing_audio_files.include?(filename)
    already_has_audio_file = false
    puts "\nalready_has_audio_file: #{voice}\n" if already_has_audio_file
    # audio_file = audio_files.find_by(filename: filename)

    audio_file = audio_files.last
    puts "Audio File: #{audio_file.inspect}"

    if already_has_audio_file && audio_file
      self.audio_url = default_audio_url(audio_file)
    else
      audio_file = create_audio_from_text(name, voice)
      puts "Audio File: #{audio_file.inspect}"
      puts "last audio file: #{audio_files.last.inspect}"
      if audio_file.is_a?(Integer) || audio_file.nil?
        puts "Error creating audio file: #{audio_file}"
        return
      end
      self.audio_url = default_audio_url(audio_file)
    end
    puts "Audio URL: #{audio_url}"
    result = save
    puts "Save Result: #{result}"
    result
  end

  def existing_audio_files
    return [] unless audio_files.attached?
    puts "Existing Audio Files: #{audio_files[0].inspect}"
    names = audio_files_blobs.map(&:filename)
    puts "Existing Audio Files: #{names}"
    names
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

  def self.categories
    ["general", "welcome", "featured", "popular", "seasonal", "routines", "emotions", "actions", "animals", "food", "people", "places", "things", "colors", "shapes", "numbers", "letters"]
  end

  def self.common_words
    ["I", "you", "he", "she", "it", "we", "they", "that", "this", "the", "a", "is", "can", "will", "do", "don't", "go", "want",
     "please", "thank you", "yes", "no", "and", "help", "hello", "goodbye", "hi", "bye", "stop", "start", "more", "less", "big", "small"]
  end

  def set_number_of_columns
    return unless number_of_columns.nil?
    self.number_of_columns = self.large_screen_columns
  end

  def needs_display_image?
    display_image_url.blank?
  end

  def update_display_image
    if ["Image", "PredefinedResource"].include?(parent_type)
      if parent_type == "Image"
        parent_user_id = parent.user_id
        parent_image_url = parent.display_image_url(self.user) if parent_user_id == self.user_id
      else
        parent_image_url = parent.display_image_url
      end
      if parent_image_url.blank?
        puts "Parent Image URL is blank"
        return
      end
      self.display_image_url = parent_image_url
      self.status = "complete"
    end
  end

  def set_status
    if parent_type == "User" || predefined
      self.status = "complete"
    else
      if has_generating_images?
        self.status = "generating"
      else
        self.status = "complete"
      end
    end
    self.save!
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

  def self.predictive_default(viewing_user = nil)
    board = nil
    id_from_env = ENV["PREDICTIVE_DEFAULT_ID"]
    if viewing_user
      user_predictive_default_id = viewing_user&.settings["predictive_default_id"]
      puts "Predictive Default ID from user settings: #{user_predictive_default_id}"
      if user_predictive_default_id
        board = self.with_artifacts.find_by(id: user_predictive_default_id)
        if !board || (user_predictive_default_id === id_from_env)
          CreateCustomPredictiveDefaultJob.perform_async(viewing_user.id)
        end
      else
        CreateCustomPredictiveDefaultJob.perform_async(viewing_user.id)
      end
    end
    if id_from_env && !board
      board = self.with_artifacts.find_by(id: id_from_env)
    end
    # original_board = nil
    if !board
      # original_board = self.with_artifacts.find_by(name: "Predictive Default", user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource")
      puts "Predictive Default not found"
      predefined_resource = PredefinedResource.find_or_create_by name: "Predictive Default", resource_type: "Board"
      board = self.create(name: "Predictive Default", user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource", parent_id: predefined_resource.id)
    end

    # if viewing_user && board
    #   viewing_user.settings["predictive_default_id"] = board.id
    #   viewing_user.save!
    # end

    board
  end

  def self.create_custom_predictive_default_for_user(new_user)
    predefined_resource = PredefinedResource.find_or_create_by name: "Predictive Default", resource_type: "Board"
    board = self.create(name: "Custom Predictive Default", user_id: new_user.id, parent_type: "PredefinedResource", parent_id: predefined_resource.id)
    if board
      new_user.settings["predictive_default_id"] = board.id
      new_user.save!
    end
    board
  end

  def self.predictive_default_id
    id_from_env = ENV["PREDICTIVE_DEFAULT_ID"]
    if id_from_env
      return id_from_env.to_i
    else
      board = self.where(name: "Predictive Default", user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource").first
      board&.id&.to_i
    end
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
    Board.with_artifacts.find_or_create_by!(name: "Predictive Default", user_id: admin_user.id, parent: predefined_resource)
  end

  def set_default_voice
    self.voice = user.settings["voice"]["name"] || "echo"
  end

  def set_voice
    board_images.includes(:image).each do |bi|
      bi.create_voice_audio(voice)
    end
  end

  def remaining_images
    Image.public_img.non_menu_images.excluding(images)
  end

  def open_ai_opts
    {}
  end

  def set_display_image
    new_doc = image_docs.first
    self.display_image_url = new_doc.display_url if new_doc
    # self.save!
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

  def find_or_create_images_from_word_list(word_list)
    unless word_list && word_list.any?
      Rails.logger.debug "No word list"
      return
    end
    if word_list.is_a?(String)
      word_list = word_list.split(" ")
    end
    if word_list.count > 50
      Rails.logger.debug "Too many words"
      return
    end
    word_list.each do |word|
      word = word.downcase
      image = user.images.find_by(label: word)
      image = Image.public_img.find_by(label: word, user_id: [User::DEFAULT_ADMIN_ID, nil]) unless image
      found_image = image
      image = Image.public_img.create(label: word, user_id: user_id) unless image
      self.add_image(image.id)
    end
    # self.reset_layouts
    self.save!
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
      # Don't add the same image twice
      puts "Image already exists"
      return
    else
      new_board_image = board_images.new(image_id: image_id.to_i, voice: self.voice, position: board_images.count)
      if layout
        new_board_image.layout = layout
        new_board_image.skip_initial_layout = true
        new_board_image.save
      else
        new_board_image.save
        new_board_image.set_initial_layout!
        # new_board_image.layout = {}

        # new_board_image.layout["lg"] = next_available_cell("lg").merge("i" => new_board_image.id.to_s)
        # new_board_image.layout["md"] = next_available_cell("md").merge("i" => new_board_image.id.to_s)
        # new_board_image.layout["sm"] = next_available_cell("sm").merge("i" => new_board_image.id.to_s)
        new_board_image.save
      end
      @image = Image.with_artifacts.find(image_id)
      if @image.existing_voices.include?(self.voice)
        new_board_image.voice = self.voice
      else
        @image.find_or_create_audio_file_for_voice(self.voice)
      end

      unless new_board_image.save
        Rails.logger.debug "new_board_image.errors: #{new_board_image.errors.full_messages}"
      end
    end
    Rails.logger.error "NO IMAGE FOUND" unless new_board_image
    new_board_image.src = @image.display_image_url(self.user)
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
      cloned_user_id = User::DEFAULT_ADMIN_ID
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
    @cloned_board.predefined = false
    @cloned_board.save
    @images.each do |image|
      layout = @layouts.find { |l| l[0] == image.id }&.second
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

  def margin_settings_valid_for_all_screen_sizes?
    margin_settings_valid_for_screen_size?("sm") && margin_settings_valid_for_screen_size?("md") && margin_settings_valid_for_screen_size?("lg")
  end

  def margin_settings_valid_for_screen_size?(screen_size)
    margin_settings.is_a?(Hash) && margin_settings.keys.sort.include?(screen_size) && margin_settings[screen_size].is_a?(Hash)
  end

  def set_display_margin_settings
    settings = margin_settings || {}
    ["lg", "md", "sm"].each do |screen_size|
      unless margin_settings_valid_for_screen_size?(screen_size)
        settings[screen_size] = { "x" => 5, "y" => 5 }
      end
    end
    self.margin_settings = settings
    self.save!
  end

  def self.grid_sizes
    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20"]
  end

  def words
    @words ||= board_images.pluck(:label)
  end

  def api_view_with_images(viewing_user = nil)
    @board_images = board_images.includes(:image).uniq
    downcased_common_words = Board.common_words.map(&:downcase)
    existing_words = @board_images.pluck(:label).map(&:downcase)
    missing_common_words = downcased_common_words - existing_words
    {
      id: id,
      name: name,
      description: description,
      category: category,
      common_words: Board.common_words,
      # word_list: words,
      word_list: existing_words,
      missing_common_words: missing_common_words,
      data: data,
      parent_type: parent_type,
      parent_id: parent_id,
      parent_description: parent_type === "User" ? "User" : parent&.to_s,
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
      margin_settings: margin_settings,
      has_generating_images: has_generating_images?,
      current_user_teams: [],
      # current_user_teams: viewing_user ? viewing_user.teams.map(&:api_view) : [],
      # images: board_images.includes(image: [:docs, :audio_files_attachments, :audio_files_blobs]).map do |board_image|
      images: @board_images.map do |board_image|
        puts "invaild layout: #{board_image.layout}" if board_image.layout_invalid?
        @image = board_image.image
        is_owner = @image.user_id == viewing_user&.id
        is_predictive = @image.predictive?
        @image_predictive_board = @image.predictive_board
        {
          id: @image.id,
          # id: board_image.id,
          predictive_board_id: @image_predictive_board&.id,
          board_image_id: board_image.id,
          is_owner: is_owner,
          is_predictive: is_predictive,
          dynamic: is_owner && is_predictive,
          label: board_image.label,
          image_prompt: board_image.image_prompt,
          bg_color: @image.bg_class,
          text_color: @image.text_color,
          next_words: board_image.next_words,
          position: board_image.position,
          src: @image_predictive_board&.display_image_url || @image.display_image_url(viewing_user),
          audio: board_image.audio_url,
          audio_url: board_image.audio_url,
          voice: board_image.voice,
          layout: board_image.layout,
          added_at: board_image.added_at,
          # image_last_added_at: board_image.image_last_added_at,
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
      group_layout: group_layout,
      position: position,
      data: data,
      description: description,
      parent_type: parent_type,
      predefined: predefined,
      number_of_columns: number_of_columns,
      status: status,
      token_limit: token_limit,
      cost: cost,
      display_image_url: display_image_url,
      # floating_words: words,
      user_id: user_id,
      voice: voice,
      margin_settings: margin_settings,
    }
  end

  def user_api_view
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
      voice: voice,
      created_at: created_at,
      updated_at: updated_at,
      margin_settings: margin_settings,
    }
  end

  SCREEN_SIZES = %w[sm md lg].freeze

  def print_grid_layout_for_screen_size(screen_size)
    layout_to_set = []
    board_images.order(:position).each_with_index do |bi, i|
      if bi.layout[screen_size]
        layout_to_set[bi.id] = bi.layout[screen_size]
      end
    end
    layout_to_set = layout_to_set.compact # Remove nil values
    layout_to_set
  end

  def print_grid_layout
    layout_to_set = layout || {}
    SCREEN_SIZES.each do |screen_size|
      layout_to_set[screen_size] = print_grid_layout_for_screen_size(screen_size)
    end
    layout_to_set
  end

  def calculate_grid_layout_for_screen_size(screen_size, reset_layouts = false)
    num_of_columns = get_number_of_columns(screen_size)

    layout_to_set = [] # Initialize as an array

    position_all_board_images
    row_count = 0
    bi_count = board_images.count
    rows = (bi_count / num_of_columns.to_f).ceil
    ActiveRecord::Base.logger.silence do
      board_images.order(:position).each_slice(num_of_columns) do |row|
        row.each_with_index do |bi, index|
          new_layout = {}
          if bi.layout[screen_size] && reset_layouts == false
            new_layout = bi.layout[screen_size]
          else
            new_layout = { "i" => bi.id.to_s, "x" => index, "y" => row_count, "w" => 1, "h" => 1 }
          end

          bi.layout[screen_size] = new_layout
          bi.skip_create_voice_audio = true
          bi.save
          bi.clean_up_layout
          layout_to_set << new_layout
        end
        row_count += 1
      end
    end

    self.layout[screen_size] = layout_to_set
    self.board_images.reset
    self.save!
  end

  def set_layouts_for_screen_sizes
    calculate_grid_layout_for_screen_size("sm", true)
    calculate_grid_layout_for_screen_size("md", true)
    calculate_grid_layout_for_screen_size("lg", true)
  end

  def update_layouts_for_screen_sizes
    update_board_layout("sm")
    update_board_layout("md")
    update_board_layout("lg")
  end

  def update_board_layout(screen_size)
    self.layout = {}
    self.layout[screen_size] = {}
    board_images.each do |bi|
      bi.layout[screen_size] = bi.layout[screen_size] || { x: 0, y: 0, w: 1, h: 1 } # Set default layout
      bi_layout = bi.layout[screen_size].merge("i" => bi.id.to_s)
      self.layout[screen_size][bi.id] = bi_layout
    end
    self.save
    self.board_images.reset
  end

  def reset_layouts
    self.layout = {}
    self.set_layouts_for_screen_sizes
    self.save!
  end

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
      if bi.nil?
        Rails.logger.debug "BoardImage not found for image_id: #{id_key}"
        next
      end
      bi.layout[screen_size] = layout_hash
      bi.clean_up_layout
      bi.save!
    end
    self.layout[screen_size] = layout_to_set
    self.board_images.reset
    self.save!
  end

  def get_number_of_columns(screen_size = "lg")
    case screen_size
    when "sm"
      num_of_columns = self.small_screen_columns > 0 ? self.small_screen_columns : 3
    when "md"
      num_of_columns = self.medium_screen_columns > 0 ? self.medium_screen_columns : 8
    when "lg"
      num_of_columns = self.large_screen_columns > 0 ? self.large_screen_columns : 12
    else
      num_of_columns = self.large_screen_columns > 0 ? self.large_screen_columns : 12
    end
  end

  def grid_layout(screen_size = "lg")
    layout_to_set = []
    board_images.order(:position).map do |bi|
      puts "screen_size: #{screen_size}"
      puts "Board Image: #{bi.layout.blank?}"
      if bi.layout.blank?
        puts "No layout for board image: #{bi.id}"
        bi.layout = { i: bi.id.to_s, x: 0, y: 0, w: 1, h: 1 }
        bi.save!
      end
      puts "Board Image Layout: #{bi.layout}"
      board_layout = bi.layout.with_indifferent_access
      layout_for_screen = board_layout[screen_size] || {}
      layout_to_set << layout_for_screen
    end
  end

  def next_available_cell(screen_size = "lg")
    # Create a hash to track occupied cells
    occupied = Hash.new { |hash, key| hash[key] = [] }
    self.update_board_layout(screen_size)
    grid = self.layout[screen_size] || []
    columns = get_number_of_columns(screen_size)

    # Mark existing cells as occupied
    grid.each do |cell|
      cell_layout = cell[1]
      x, y, w, h = cell_layout.values_at("x", "y", "w", "h")
      x ||= 0
      y ||= 0
      w ||= 1
      h ||= 1
      w.times do |w_offset|
        h.times do |h_offset|
          occupied[y + h_offset] << (x + w_offset)
        end
      end
    end

    # Search for the first unoccupied 1x1 cell
    (0..Float::INFINITY).each do |y|
      (0...columns).each do |x|
        unless occupied[y].include?(x)
          return { "x" => x, "y" => y, "w" => 1, "h" => 1 }
        end
      end
    end
  end

  def format_board_with_ai(screen_size = "lg")
    num_of_columns = get_number_of_columns(screen_size)
    @board_images = board_images.includes(:image)
    words = @board_images.pluck(:label)
    max_num_of_rows = (words.count / num_of_columns.to_f).ceil
    response = OpenAiClient.new({}).generate_formatted_board(name, num_of_columns, words, max_num_of_rows)
    if response
      parsed_response = JSON.parse(response)
      grid_response = parsed_response["grid"]
      personable_explanation = "Personable Explanation: " + parsed_response["personable_explanation"]
      professional_explanation = "Professional Explanation: " + parsed_response["professional_explanation"]
      explanation = personable_explanation + "\n" + professional_explanation
      self.data["personable_explanation"] = personable_explanation
      self.data["professional_explanation"] = professional_explanation
      grid_response.each_with_index do |item, index|
        label = item["word"]
        board_image = @board_images.joins(:image).find_by(images: { label: label })
        image = board_image&.image

        if board_image
          item["size"] ||= [1, 1]
          if item["frequency"].present?
            if item["frequency"] === "high"
              item["size"] = [2, 2]
            end

            puts "Frequency: #{item["frequency"]}"
          end

          board_image.data["label"] = label
          board_image.data[screen_size] ||= {}
          board_image.data[screen_size]["frequency"] = item["frequency"]
          board_image.data[screen_size]["size"] = item["size"]
          board_image.data["part_of_speech"] = item["part_of_speech"]
          board_image.data["bg_color"] = image.background_color_for(item["part_of_speech"])

          board_image.position = index
          board_image.save!

          image.part_of_speech = item["part_of_speech"] if item["part_of_speech"].present? && image.part_of_speech.blank?
          image.save!

          x_coordinate = item["position"][0]
          y_coordinate = item["position"][1]
          puts "Label: #{label} - X: #{x_coordinate} - Y: #{y_coordinate} Max Rows: #{max_num_of_rows}"
          if x_coordinate >= num_of_columns
            x_coordinate = 0
          end
          # max_num_of_rows = (images.count / num_of_columns.to_f).ceil
          if y_coordinate >= max_num_of_rows
            y_coordinate = max_num_of_rows
          end

          board_image.layout ||= {}
          board_image.layout[screen_size] = { "x" => x_coordinate, "y" => y_coordinate, "w" => 1, "h" => 1, "i" => board_image.id.to_s }
          board_image.save!
        else
          puts "Board Image not found for label: #{label}"
        end
      end
      if explanation
        self.description = explanation
        self.save!
      end
    end
    self
  end

  def api_view_with_predictive_images(viewing_user = nil)
    @board_images = board_images.includes(image: [:docs, :audio_files_attachments, :audio_files_blobs, :predictive_boards])
    {
      id: id,
      name: name,
      description: description,
      can_edit: user_id == viewing_user&.id || viewing_user&.admin?,
      category: category,
      parent_type: parent_type,
      parent_id: parent_id,
      parent_description: parent_type === "User" ? "User" : parent&.to_s,
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
      # floating_words: words,
      user_id: user_id,
      voice: voice,
      created_at: created_at,
      updated_at: updated_at,
      margin_settings: margin_settings,
      has_generating_images: has_generating_images?,
      current_user_teams: [],
      images: @board_images.map do |board_image|
        @board_image = board_image

        @label = @board_image.label

        @image = viewing_user ? viewing_user.images.with_artifacts.find_by(label: @label) : nil
        if @image.nil?
          @image = Image.with_artifacts.public_img.find_by(label: @label, user_id: [User::DEFAULT_ADMIN_ID, nil])
        end

        image = @image || board_image.image

        is_owner = viewing_user && image.user_id == viewing_user&.id

        @predictive_board_id = image&.predictive_board_for_user(viewing_user&.id)&.id
        @global_default_id = Board.predictive_default_id
        is_predictive = @predictive_board_id != @global_default_id
        {
          id: image.id,
          image_user_id: image.user_id,
          predictive_board_id: @predictive_board_id,
          is_owner: is_owner,
          is_predictive: is_predictive,
          dynamic: is_owner && is_predictive,
          global_default_id: @global_default_id,
          board_image_id: @board_image.id,
          label: @board_image.label,
          image_prompt: @board_image.image_prompt,
          bg_color: image.bg_class,
          text_color: @board_image.text_color,
          next_words: @board_image.next_words,
          position: @board_image.position,
          src: image.display_image_url(viewing_user),
          audio: @board_image.audio_url,
          audio_url: @board_image.audio_url,
          voice: @board_image.voice,
          layout: @board_image.layout,
          added_at: @board_image.added_at,
          image_last_added_at: @board_image.image_last_added_at,
          part_of_speech: image.part_of_speech,

          status: @board_image.status,
        }
      end,
    # layout: layout,
    }
  end

  def get_words(name_to_send, number_of_words, words_to_exclude = [])
    words_to_exclude = board_images.pluck(:label).map { |w| w.downcase }
    response = OpenAiClient.new({}).get_additional_words(name_to_send, number_of_words, words_to_exclude)
    if response
      words = response[:content].gsub("```json", "").gsub("```", "").strip
      if words.blank? || words.include?("NO ADDITIONAL WORDS")
        return
      end
      if valid_json?(words)
        words = JSON.parse(words)
      else
        puts "INVALID JSON: #{words}"
        start_index = words.index("{")
        end_index = words.rindex("}")
        words = words[start_index..end_index]
        words = transform_into_json(words)
      end
    else
      Rails.logger.error "*** ERROR - get_words *** \nDid not receive valid response. Response: #{response}\n"
    end
    # words["additional_words"]
    words_to_include = words["additional_words"] || []
    words_to_include = words_to_include.map { |w| w.downcase }
    words_to_include = words_to_include - words_to_exclude
    words_to_include = words_to_include.uniq
    puts "Words to include: #{words_to_include}"
    words_to_include
  end

  # ["want", "need", "help", "stop", "more", "yes", "no", "like", "go", "come", "look", "play", "eat", "drink",
  #  "feel", "open", "close", "turn", "give", "take", "find", "make", "read", "write",
  #  "listen", "see", "hear", "touch", "sit", "stand", "i", "to", "you", "happy", "sad", "big",
  #  "little", "fast", "slow", "hot", "cold", "good", "bad", "here", "there"]

  def get_word_suggestions(name_to_use, number_of_words)
    response = OpenAiClient.new({}).get_word_suggestions(name_to_use, number_of_words)
    if response
      word_suggestions = response[:content].gsub("```json", "").gsub("```", "").strip
      if word_suggestions.blank? || word_suggestions.include?("NO WORDS")
        return
      end
      if valid_json?(word_suggestions)
        word_suggestions = JSON.parse(word_suggestions)
      else
        puts "INVALID JSON: #{word_suggestions}"
        start_index = word_suggestions.index("{")
        end_index = word_suggestions.rindex("}")
        word_suggestions = word_suggestions[start_index..end_index]
        word_suggestions = transform_into_json(word_suggestions)
      end
    else
      Rails.logger.error "*** ERROR - get_word_suggestions *** \nDid not receive valid response. Response: #{response}\n"
    end
    word_suggestions["words"]
  end
end
