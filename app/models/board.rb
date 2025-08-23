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
#  data                  :jsonb
#  group_layout          :jsonb
#  image_parent_id       :integer
#  board_type            :string
#  obf_id                :string
#  board_group_id        :integer
#  language              :string           default("en")
#  board_images_count    :integer          default(0), not null
#  published             :boolean          default(FALSE)
#  favorite              :boolean          default(FALSE)
#  vendor_id             :bigint
#
require "zip"

class Board < ApplicationRecord
  has_rich_text :display_description
  belongs_to :user
  belongs_to :vendor, optional: true
  paginates_per 100
  belongs_to :parent, polymorphic: true
  has_many :board_group_boards, dependent: :destroy
  has_many :board_groups, through: :board_group_boards
  has_many :board_images, dependent: :destroy
  has_many :visible_board_images, -> { where(hidden: false) }, class_name: "BoardImage"
  has_many :images, through: :board_images
  has_many :docs
  has_many :team_boards, dependent: :destroy
  has_many :teams, through: :team_boards
  has_many :team_users, through: :teams
  has_many :users, through: :team_users
  has_many_attached :audio_files
  has_one_attached :preset_display_image
  has_many :child_boards, dependent: :destroy
  belongs_to :image_parent, class_name: "Image", optional: true
  has_many :word_events

  include WordEventsHelper

  attr_accessor :skip_create_voice_audio

  validates :slug, uniqueness: true

  include UtilHelper
  include BoardsHelper

  include PgSearch::Model
  pg_search_scope :search_by_name,
                  against: :name,
                  using: {
                    tsearch: { prefix: true },
                  }

  scope :for_user, ->(user) { where(user: user).or(where(user_id: User::DEFAULT_ADMIN_ID, predefined: true)) }
  scope :alphabetical, -> { order(Arel.sql("LOWER(name) ASC")) }
  scope :with_image_parent, -> { where.associated(:image_parent) }
  scope :searchable, -> { where(board_type: ["static", "dynamic", "category", "predictive", "scenario"]) }
  scope :menus, -> { where(parent_type: "Menu") }
  scope :non_menus, -> { where.not(parent_type: "Menu") }
  scope :user_made, -> { where(parent_type: "User") }
  scope :scenarios, -> { where(parent_type: "OpenaiPrompt") }
  scope :user_made_with_scenarios, -> { where(parent_type: ["User", "OpenaiPrompt", "PredefinedResource"], predefined: false) }
  scope :user_made_with_scenarios_and_menus, -> { where(parent_type: ["User", "OpenaiPrompt", "Menu", "PredefinedResource"], predefined: false) }
  scope :predefined, -> { where(predefined: true) }
  scope :ai_generated, -> { where(parent_type: "OpenaiPrompt") }
  scope :with_less_than_10_images, -> { joins(:images).group("boards.id").having("count(images.id) < 10") }
  scope :with_less_than_x_images, ->(x) { joins(:images).group("boards.id").having("count(images.id) < ?", x) }
  scope :without_images, -> { left_outer_joins(:images).where(images: { id: nil }) }

  scope :created_this_week, -> { where("created_at > ?", 1.week.ago) }
  scope :created_before_this_week, -> { where("created_at < ?", 8.days.ago) }
  scope :created_today, -> { where("created_at > ?", 1.day.ago.end_of_day) }
  scope :created_yesterday, -> { where("created_at > ? AND created_at < ?", 1.day.ago.beginning_of_day, Time.zone.now.beginning_of_day) }
  scope :communikate_boards, -> { where("name ILIKE ?", "%CommuniKate%") }

  scope :public_boards, -> { where(user_id: User::DEFAULT_ADMIN_ID, predefined: true, favorite: true).where.not(parent_type: "Menu") }
  scope :public_menu_boards, -> { where(user_id: User::DEFAULT_ADMIN_ID, predefined: true, favorite: true, parent_type: "Menu") }
  scope :without_preset_display_image, -> { where.missing(:preset_display_image_attachment) }
  scope :preset, -> { where(predefined: true) }
  scope :welcome, -> { where(category: "welcome", predefined: true) }
  scope :published, -> { where(published: true) }
  POSSIBLE_BOARD_TYPES = %w[board category user image menu].freeze

  scope :dynamic_defaults, -> { where(name: "Dynamic Default", parent_type: "PredefinedResource") }

  SAFE_FILTERS = %w[all welcome preset featured popular general seasonal routines emotions actions animals food people places things colors shapes numbers letters].freeze

  # scope :with_artifacts, -> { includes({ board_images: { image: [:docs, :audio_files_attachments, :audio_files_blobs] } }) }
  scope :with_artifacts, -> { includes({ board_images: [{ image: [{ docs: [:image_attachment, :image_blob, :user_docs] }, :audio_files_attachments, :audio_files_blobs, :user, :category_boards] }] }, :image_parent) }

  include ImageHelper

  before_save :set_voice, if: :voice_changed?
  before_save :set_default_voice, unless: :voice?
  # before_save :update_display_image, unless: :display_image_url?
  before_save :update_preset_display_image_url, if: :display_image_url_changed?

  # before_save :set_board_type
  before_save :clean_up_name
  before_save :validate_data
  before_save :set_vendor_id

  before_save :set_display_margin_settings, unless: :margin_settings_valid_for_all_screen_sizes?

  before_create :set_slug

  before_create :set_screen_sizes, :set_number_of_columns
  before_destroy :delete_menu, if: :parent_type_menu?
  after_initialize :set_initial_layout, if: :layout_empty?

  def self.recently_used(viewing_user)
    if viewing_user.is_a?(User)
      Board.joins(:word_events).where(user_id: viewing_user.id).order("word_events.created_at DESC").limit(10)
    else
      boards = Board.with_artifacts.where(user_id: User::DEFAULT_ADMIN_ID).order("updated_at DESC").limit(10)
    end
  end

  def self.common_boards
    board_names = ["Numbers", "Sizes", "Greetings", "Little Words"]
    Board.with_artifacts.where(user_id: User::DEFAULT_ADMIN_ID, name: board_names, predefined: true)
  end

  def self.dynamic
    where(board_type: ["dynamic", "predictive"]).distinct
  end

  def self.categories
    where(board_type: "category")
  end

  def self.user_made
    where(board_type: "user")
  end

  def self.ai_generated
    where(board_type: "ai_generated")
  end

  def self.predictive
    where(board_type: "predictive")
  end

  def self.static
    where(board_type: ["static", "scenario"])
  end

  def self.with_identical_images(name, user = nil)
    user_id = user ? user.id : User::DEFAULT_ADMIN_ID
    user_boards = Board.includes(:images).where(name: name, user_id: user_id)
    board_data = {}
    user_boards.each do |b|
      img_ids = b.images.pluck(:id)
      board_data[b.id] = img_ids
    end
    board_ids = []
    board_data.each do |k, v|
      board_data.each do |k2, v2|
        next if k == k2
        if v.sort == v2.sort
          board_ids << k2
        end
      end
    end
    boards = user_boards.where(id: board_ids)
    boards.count > 1 ? boards : []
  end

  def self.clean_up_idential_boards_for(name, user = nil)
    boards = with_identical_images(name, user)
    return unless boards.any?
    board_to_keep = boards.first
    boards.each do |board|
      next if board == board_to_keep
      # board.board_images.destroy_all
      board.destroy!
    end
  end

  def self.clean_up_all_identical_for(user_id)
    user = User.includes({ boards: [{ board_images: :image }] }).find(user_id)
    user.boards.each do |board|
      clean_up_idential_boards_for(board.name, user)
      sleep 1
    end
  end

  def self.clean_up_duplicate(name, user = nil, dry_run = true)
    user_id = user ? user.id : User::DEFAULT_ADMIN_ID
    boards = Board.includes(:images).where(name: name, user_id: user_id)
    return unless boards.count > 1
    board_to_keep = boards.max_by { |b| b.images.count }
    board_count = 0
    boards.each do |board|
      next if board == board_to_keep
      # board.board_images.destroy_all
      board_count += 1
      board.destroy! unless dry_run
    end
    puts "#{board_count - 1} boards deleted"
  end

  def set_initial_layout
    self.layout = { "lg" => [], "md" => [], "sm" => [] }
  end

  # const getBoardIcon = (board: Board) => {
  #   console.log("Getting icon for board:", board.name.includes("Numbers"));
  #   if (board.name.toLowerCase().includes("numbers")) {
  #     return <i className="fa-solid fa-hashtag"></i>;
  #   } else if (board.name.toLowerCase().includes("greetings")) {
  #     return <i className="fa-solid fa-handshake"></i>;
  #   } else if (board.name.toLowerCase().includes("sizes")) {
  #     return <IonIcon icon={expandOutline} />;
  #   } else if (board.name.includes("Little Words")) {
  #     return <IonIcon icon={diceOutline} />;
  #   } else if (board.name.toLowerCase().includes("feelings")) {
  #     return <IonIcon icon={happyOutline} />;
  #   } else if (board.name.toLowerCase().includes("family")) {
  #     return <IonIcon icon={peopleOutline} />;
  #   } else if (board.name.toLowerCase().includes("home page")) {
  #     return <IonIcon icon={homeOutline} />;
  #   } else if (board.name.toLowerCase().includes("daily routine")) {
  #     return <IonIcon icon={shirtOutline} />;
  #   } else if (board.name.toLowerCase().includes("bathroom")) {
  #     return <IonIcon icon={waterOutline} />;
  #   } else if (board.name.toLowerCase().includes("sleep")) {
  #     return <IonIcon icon={bedOutline} />;
  #   } else {
  #     return <IonLabel className="mx-2 text-xs">{board.slug}</IonLabel>;
  #   }
  # };

  def ionic_icon
    return "hash" if name&.downcase&.include?("numbers")
    return "handshake" if name&.downcase&.include?("greetings")
    return "expand" if name&.downcase&.include?("sizes")
    return "dice" if name&.downcase&.include?("little words")
    return "happy" if name&.downcase&.include?("feelings")
    return "people" if name&.downcase&.include?("family")
    return "home" if name&.downcase&.include?("home page")
    return "shirt" if name&.downcase&.include?("daily routine")
    return "water" if name&.downcase&.include?("bathroom")
    return "bed" if name&.downcase&.include?("sleep")
    return "shirt" if name&.downcase&.include?("routine")

    "default"
  end

  # def ionic_icon
  #   return "<i className='fa-solid fa-handshake'></i>" if name&.downcase&.include?("greetings")
  #   return "<i className='fa-solid fa-expand'></i>" if name&.downcase&.include?("sizes")
  #   return "<i className='fa-solid fa-dice'></i>" if name&.downcase&.include?("little words")
  #   return "<i className='fa-solid fa-happy'></i>" if name&.downcase&.include?("feelings")
  #   return "<i className='fa-solid fa-people'></i>" if name&.downcase&.include?("family")
  #   return "<i className='fa-solid fa-home'></i>" if name&.downcase&.include?("home page")
  #   return "<i className='fa-solid fa-shirt'></i>" if name&.downcase&.include?("daily routine")
  #   return "<i className='fa-solid fa-water'></i>" if name&.downcase&.include?("bathroom")
  #   return "<i className='fa-solid fa-bed'></i>" if name&.downcase&.include?("sleep")
  #   return "<i className='fa-solid fa-shirt'></i>" if name&.downcase&.include?("routine")

  #   "<i className='fa-solid fa-default'></i>"
  # end

  # def set_slug
  #   return unless name.present? && slug.blank?

  #   slug = name.parameterize
  #   existing_board = Board.find_by(slug: slug)
  #   if existing_board
  #     Rails.logger.warn "Board with slug '#{slug}' already exists. Generating a new slug."
  #     random = SecureRandom.hex(8)
  #     slug = "#{slug}-#{random}"
  #   end
  #   self.slug = slug
  # end

  def set_vendor_id
    return if vendor_id.present? || !user
    self.vendor_id = user.vendor_id if user && user.vendor_id
  end

  def layout_empty?
    layout.blank?
  end

  validates :name, presence: true

  def clean_up_scenarios
    Scenario.where(board_id: id).destroy_all
  end

  def validate_data
    self.data ||= {}
    # data["personable_explanation"].gsub("Personable Explanation: ", "") if data["personable_explanation"]
    self.data["personable_explanation"] = data["personable_explanation"].gsub("Personable Explanation: ", "") if data["personable_explanation"]
    self.data["professional_explanation"] = data["professional_explanation"].gsub("Professional Explanation: ", "") if data["professional_explanation"]
    # self.data["current_word_list"] = words
  end

  def self.set_preset_display_image_from_url(boards)
    boards.each do |board|
      next if board.preset_display_image.attached?
      board_data = board.data || {}
      next unless board_data["display_image_url"]
      board.preset_display_image.attach(io: URI.open(board_data["display_image_url"]), filename: "display_image.jpg")
    end
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

  def display_preset_image_url
    image_key = preset_display_image&.key

    cdn_url = "#{ENV["CDN_HOST"]}/#{image_key}" if image_key

    image_key ? cdn_url : nil
  end

  # OBF helper methods

  def url
    base_url = ENV["FRONT_END_URL"] || "localhost:8100"
    "#{base_url}/boards/#{id}"
  end

  def data_url
    base_url = ENV["API_URL"] || "localhost:4000"
    "#{base_url}/api/boards/#{id}"
  end

  def license
    { "name" => "CC BY-SA 4.0", "url" => "https://creativecommons.org/licenses/by-sa/4.0/" }
  end

  def background
    bg_color
  end

  def chart_bg_color
    Profile::RANDOM_COLORS.sample
  end

  def existing_audio_files
    return [] unless audio_files.attached?
    names = audio_files_blobs.map(&:filename)
    names
  end

  def set_screen_sizes
    self.small_screen_columns = 4 if small_screen_columns.nil?
    self.medium_screen_columns = 6 if medium_screen_columns.nil?
    self.large_screen_columns = 8 if large_screen_columns.nil?
  end

  def parent_type_menu?
    parent_type == "Menu"
  end

  def delete_menu
    begin
      parent.destroy!
    rescue => e
      Rails.logger.error "Error deleting parent: #{e.inspect}"
    end
  end

  def self.board_categories
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
    parent_type == "Image" && display_image_url.blank?
  end

  def update_display_image
    if image_parent
      image_parent_url = image_parent.display_image_url(user)
      self.display_image_url = image_parent_url
      self.status = "complete"
    elsif parent_type == "Image"
      self.display_image_url = parent.display_image_url(user)
      self.status = "complete"
    elsif matching_viewer_images.any?
      self.display_image_url = matching_viewer_images.first.display_image_url(user)
      self.status = "complete"
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

  def set_board_type
    if POSSIBLE_BOARD_TYPES.include?(board_type)
      return
    end
    self.board_type = tmp_board_type
  end

  def clean_up_name
    has_source_type = false
    original_type_name = nil
    Image::SOURCE_TYPE_NAMES.each do |type_name|
      board_name = name.downcase
      type_name.downcase!
      has_source_type = board_name.include?(type_name) if board_name
      has_source_type = source_type == type_name if source_type && !has_source_type

      if has_source_type
        original_type_name = type_name.gsub("-", "").strip
        name.downcase!
        name.gsub!(type_name, "") if name
        break
      end
    end
    self.data["source_type"] = original_type_name if has_source_type
    self.name = name.strip if name
    if name.blank? || name == "Untitled Board"
      self.name = original_type_name + " Board" if original_type_name
      if name.blank?
        self.name = "Untitled Board"
      end
    end
    name
  end

  def self.predictive_default(viewing_user = nil)
    board = nil
    id_from_env = ENV["PREDICTIVE_DEFAULT_ID"]
    if viewing_user
      user_predictive_default_id = viewing_user&.settings["dynamic_board_id"]&.to_i
      if user_predictive_default_id
        board = self.with_artifacts.find_by(id: user_predictive_default_id)
      end
    end
    if id_from_env && !board
      board = self.with_artifacts.find_by(id: id_from_env&.to_i)
    end
    if !board
      board = Board.with_artifacts.find_by(user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource")
    end
    if !board
      Rails.logger.warn "Something went wrong creating Predictive Default"

      predefined_resource = PredefinedResource.find_or_create_by name: "Predictive Default", resource_type: "Board"
      board = self.create(name: "Predictive Default", user_id: User::DEFAULT_ADMIN_ID, parent_type: "PredefinedResource", parent_id: predefined_resource.id)
      board.find_or_create_images_from_word_list(self.common_words) if board
    end
    board
  end

  def resource_type
    parent.resource_type
  end

  def dynamic?
    resource_type == "Board"
  end

  def predictive?
    resource_type == "Image"
  end

  def static?
    resource_type == "User"
  end

  def category?
    resource_type == "category"
  end

  def self.create_dynamic_default_for_user(new_user)
    # predefined_resource = PredefinedResource.find_or_create_by name: "Predictive Default", resource_type: "Board"
    original_board = self.predictive_default
    board = nil
    if original_board
      board = original_board.clone_with_images(new_user.id, "Dynamic Default")
    else
      Rails.logger.error "Something went wrong attempting to clone Predictive Default"
    end
    if board
      new_user.settings["dynamic_board_id"] = board.id
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
    user_voice_settings = user.settings["voice"] || {}
    user_voice = user_voice_settings.is_a?(Hash) ? user_voice_settings["name"] : nil
    self.voice = user_voice
  end

  def set_voice
    board_images.includes(:image).each do |bi|
      bi.update!(voice: voice) if bi.voice != voice
      bi.create_voice_audio
    end
  end

  def remaining_images
    Image.public_img.non_menu_images.excluding(images)
  end

  def open_ai_opts
    {}
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

  def find_or_create_images_from_word_list(word_list)
    unless word_list && word_list.any?
      return
    end
    Rails.logger.info "Finding or creating images for word list: #{word_list.inspect}"
    if word_list.is_a?(String)
      word_list = word_list.split(" ")
    end
    if word_list.count > 50
      Rails.logger.error "Too many words - will only use the first 50"
      word_list = word_list[0..50]
    end
    word_list.each do |word|
      word = word.downcase.gsub('"', "").gsub("'", "")
      image = user.images.find_by(label: word)
      image = Image.public_img.find_by(label: word, user_id: [User::DEFAULT_ADMIN_ID, nil]) unless image
      image = Image.create(label: word) unless image
      display_doc = image.display_image_url(user)
      if display_doc.blank?
        Rails.logger.error "No display image for word: #{word}"
        image_prompt = "Create an image of #{word}"
        admin_image_present = image.docs.any? { |doc| doc.user_id == User::DEFAULT_ADMIN_ID }
        user_image_present = image.docs.any? { |doc| doc.user_id == user_id }
        Rails.logger.info "Admin image present: #{admin_image_present}, User image present: #{user_image_present}"
        # image.create_image_doc(user_id) unless user_image_present

        GenerateImageJob.perform_async(image.id, user_id, image_prompt, id) unless admin_image_present || user_image_present
        # next
      end
      self.add_image(image.id) if image && !image_ids.include?(image.id)
    end
    # self.reset_layouts
    self.save!
  end

  def remove_image(image_id)
    return unless image_ids.include?(image_id.to_i)
    bi = board_images.find_by(image_id: image_id)
    bi.destroy if bi
  end

  def add_images(image_ids)
    image_ids.each do |image_id|
      add_image(image_id)
    end
  end

  def add_image(image_id, layout = nil)
    new_board_image = nil
    return if image_id.blank?
    @image = Image.with_artifacts.find_by(id: image_id)
    if image_ids.include?(image_id.to_i)
      # Don't add the same image twice
      new_board_image = board_images.find_by(image_id: image_id.to_i)
    else
      language_settings = @image.language_settings || {}
      language_settings[self.language] = { "display_label" => @image.label, "label" => @image.label }
      new_board_image = board_images.new(image_id: image_id.to_i, voice: self.voice, position: board_images_count, language: self.language)
      new_board_image.set_labels
      if layout
        new_board_image.layout = layout
        if new_board_image.layout_invalid?
          new_board_image.set_initial_layout!
        end
        new_board_image.skip_initial_layout = true
        new_board_image.save
      else
        new_board_image.save
        new_board_image.set_initial_layout!
      end
      unless @image
        Rails.logger.error "Image not found: #{image_id}"
        return
      end

      if @image.existing_voices.include?(self.voice)
        new_board_image.voice = self.voice
      else
        # @image.find_or_create_audio_file_for_voice(self.voice)
        SaveAudioJob.perform_async([image_id], self.voice)
      end

      new_board_image.src = @image.display_image_url(self.user)

      unless new_board_image.save
        Rails.logger.error "new_board_image.errors: #{new_board_image.errors.full_messages}"
        return
      end
      self.save!
    end
    Rails.logger.error "NO IMAGE FOUND" unless new_board_image
    new_board_image
  end

  def clone_with_images(cloned_user_id, new_name)
    if new_name.blank?
      new_name = name + " copy"
    end
    cloned_slug = new_name.parameterize
    Rails.logger.info ">>>Cloning board: #{id} to new board with slug: #{cloned_slug} for user: #{cloned_user_id}"
    existing_board = Board.find_by(slug: cloned_slug)
    if existing_board
      random_string = SecureRandom.hex(4)
      Rails.logger.warn "Board #{id} has a duplicate slug '#{cloned_slug}', generating a new one."
      cloned_slug = "#{cloned_slug}-#{random_string}"
    end
    @source = self
    cloned_user = User.find(cloned_user_id)
    unless cloned_user
      cloned_user_id = User::DEFAULT_ADMIN_ID
      cloned_user = User.find(cloned_user_id)
      if !cloned_user
        return
      end
    end
    @images = @source.images
    @board_images = @source.board_images
    @layouts = @board_images.pluck(:image_id, :layout)

    @cloned_board = @source.dup
    @cloned_board.slug = cloned_slug
    @cloned_board.user_id = cloned_user_id
    @cloned_board.name = new_name
    @cloned_board.predefined = false
    @cloned_board.obf_id = nil
    @cloned_board.board_type = @source.board_type
    @cloned_board.data = nil
    @cloned_board.save
    Rails.logger.info "Cloning board: #{@source.id} to new board: #{@cloned_board.id} for user: #{cloned_user_id} SLUG: #{@cloned_board.slug}"
    unless @cloned_board.persisted?
      Rails.logger.error "Slug: #{@cloned_board.slug}"
      Rails.logger.error "Error cloning board: #{@source.id} to new board: #{@cloned_board.id} for user: #{cloned_user_id}"
      Rails.logger.error @cloned_board.errors.full_messages.join(", ")
      return
    end
    @board_images.each do |board_image|
      image = board_image.image
      original_image = image

      # unless image.user_id && image.user_id == @cloned_board.user_id
      #   image = Image.find_by(label: image.label, user_id: @cloned_board.user_id)
      # end

      if image.user_id
        image = Image.find_by(label: image.label, user_id: @cloned_board.user_id) if image.user_id == @cloned_board.user_id
      else
        image = Image.find_by(label: image.label, user_id: [nil, @cloned_board.user_id, User::DEFAULT_ADMIN_ID])
      end
      image = Image.create(label: original_image.label, user_id: @cloned_board.user_id) unless image
      layout = @layouts.find { |l| l[0] == original_image.id }&.second
      # new_board_image = @cloned_board.add_image(image.id, layout)
      new_board_image = board_image.dup
      if new_board_image
        new_board_image.image = image
        new_board_image.board = @cloned_board
        new_board_image.image_id = image.id
        new_board_image.layout = layout if layout
        new_board_image.display_label = board_image.display_label

        new_board_image.voice = board_image.voice
        new_board_image.predictive_board_id = board_image.predictive_board_id
        new_board_image.save
      end
    end
    if @cloned_board.save
      UpdateUserBoardsJob.perform_async(@cloned_board.id, @source.id) if @source.user_id != cloned_user_id
      @cloned_board
    else
      Rails.logger.error "Error cloning board: #{@cloned_board}"
    end
  end

  def update_user_boards_after_cloning(source_board)
    user_boards = user.board_images.where(predictive_board_id: source_board.id)
    cloned_board = self
    user_boards.each do |bi|
      bi.predictive_board_id = cloned_board.id
      if bi.save
        puts "Saved"
      else
        puts "Error saving"
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
        settings[screen_size] = { "x" => 3, "y" => 3 }
      end
    end
    self.margin_settings = settings
    self.save!
  end

  def self.grid_sizes
    ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11", "12", "13", "14", "15", "16", "17", "18", "19", "20"]
  end

  # def words
  #   @words ||= board_images.order(:position).pluck(:label)
  # end

  def current_word_list
    ActiveRecord::Base.logger.silence do
      data ||= {}
      if data["current_word_list"].blank?
        self.data ||= {}
        words = board_images.order(:position).pluck(:label)
        if words.blank?
          if user_id == User::DEFAULT_ADMIN_ID
            destroy
          end
          return []
        end
        self.data["current_word_list"] = words
        save
        words
      else
        data["current_word_list"]
      end
    end
  end

  def get_commons_words
    @board_images = board_images.includes(:image).uniq
    downcased_common_words = Board.common_words.map(&:downcase)
    existing_words = current_word_list ? current_word_list.map(&:downcase) : []
    missing_common_words = downcased_common_words - existing_words
    { missing_common_words: missing_common_words, existing_words: existing_words }
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

    # position_all_board_images
    row_count = 0
    bi_count = board_images_count
    rows = (bi_count / num_of_columns.to_f).ceil
    ActiveRecord::Base.logger.silence do
      board_images.order(:position).each_slice(num_of_columns) do |row|
        row.each_with_index do |bi, index|
          new_layout = {}
          if bi.layout[screen_size] && reset_layouts == false
            new_layout = bi.layout[screen_size]
          else
            width = bi.layout[screen_size] ? bi.layout[screen_size]["w"] : 1
            height = bi.layout[screen_size] ? bi.layout[screen_size]["h"] : 1
            new_layout = { "i" => bi.id.to_s, "x" => index, "y" => row_count, "w" => width, "h" => height }
          end

          bi.layout[screen_size] = new_layout
          bi.skip_create_voice_audio = true
          bi.save!
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

  # def set_layouts_for_screen_sizes
  #   calculate_grid_layout_for_screen_size("sm", true)
  #   calculate_grid_layout_for_screen_size("md", true)
  #   calculate_grid_layout_for_screen_size("lg", true)
  # end

  # def update_layouts_for_screen_sizes
  #   update_board_layout("sm")
  #   update_board_layout("md")
  #   update_board_layout("lg")
  # end

  def update_board_layout(screen_size)
    self.layout = {}
    self.layout[screen_size] = {}
    board_images.order(:position).each do |bi|
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
    # self.update_layouts_for_screen_sizes
    self.save!
  end

  def update_grid_layout(layout_to_set, screen_size)
    layout_for_screen_size = self.layout[screen_size] || []
    unless layout_to_set.is_a?(Array)
      return
    end
    layout_to_set.each_with_index do |layout_item, i|
      id_key = layout_item[:i]
      layout_hash = layout_item.with_indifferent_access
      id_key = layout_hash[:i] || layout_hash["i"]
      bi = board_images.find(id_key) rescue nil
      bi = board_images.find_by(image_id: id_key) if bi.nil?

      if bi.nil?
        next
      end
      bi.layout[screen_size] = layout_hash
      bi.position = i
      bi.clean_up_layout
      bi.save!
    end
    self.layout[screen_size] = layout_to_set
    self.board_images.reset
    self.save!
  end

  # def get_number_of_columns(screen_size = "lg")
  #   case screen_size
  #   when "sm"
  #     num_of_columns = self.small_screen_columns > 0 ? self.small_screen_columns : 4
  #   when "md"
  #     num_of_columns = self.medium_screen_columns > 0 ? self.medium_screen_columns : 6
  #   when "lg"
  #     num_of_columns = self.large_screen_columns > 0 ? self.large_screen_columns : 8
  #   else
  #     num_of_columns = self.large_screen_columns > 0 ? self.large_screen_columns : 12
  #   end
  # end

  def grid_layout(screen_size = "lg")
    layout_to_set = []
    board_images.order(:position).map do |bi|
      if bi.layout.blank?
        bi.layout = { i: bi.id.to_s, x: 0, y: 0, w: 1, h: 1 }
        bi.save!
      end
      board_layout = bi.layout.with_indifferent_access
      layout_for_screen = board_layout[screen_size] || {}
      layout_to_set << layout_for_screen
    end
  end

  def grid_cell_width(screen_size = "lg")
    screen_dimensions = { "sm" => 599, "md" => 650, "lg" => 769 }
    screen_dimension = screen_dimensions[screen_size]
    num_of_columns = get_number_of_columns(screen_size)
    (screen_dimension / num_of_columns).to_i
  end

  # def next_available_cell(screen_size = "lg")
  #   # Create a hash to track occupied cells
  #   occupied = Hash.new { |hash, key| hash[key] = [] }
  #   self.update_board_layout(screen_size)
  #   grid = self.layout[screen_size] || []

  #   # Mark existing cells as occupied
  #   grid.each do |cell|
  #     cell_layout = cell[1]
  #     x, y, w, h = cell_layout.values_at("x", "y", "w", "h")
  #     x ||= 0
  #     y ||= 0
  #     w ||= 1
  #     h ||= 1
  #     w.times do |w_offset|
  #       h.times do |h_offset|
  #         occupied[y + h_offset] << (x + w_offset)
  #       end
  #     end
  #   end

  #   columns = get_number_of_columns(screen_size)

  #   # Search for the first unoccupied 1x1 cell
  #   (0..Float::INFINITY).each do |y|
  #     (0...columns).each do |x|
  #       unless occupied[y].include?(x)
  #         return { "x" => x, "y" => y, "w" => 1, "h" => 1 }
  #       end
  #     end
  #   end
  # end

  # def format_board_with_ai(screen_size = "lg", maintain_existing_layout = false)
  #   num_of_columns = get_number_of_columns(screen_size)
  #   @board_images = board_images.includes(:image)
  #   existing_layout = []

  #   @board_images.each do |bi|
  #     image = bi.image
  #     @predictive_board_id = bi.predictive_board_id
  #     @predictive_board = @predictive_board_id ? Board.find_by(id: @predictive_board_id) : nil
  #     bi_layout = bi.layout[screen_size]
  #     bi.predictive_board_id = @predictive_board_id
  #     bi_data_for_screen = bi.data[screen_size] || {}
  #     w = {
  #       word: bi.label,
  #       size: [bi_layout["w"], bi_layout["h"]],
  #       board_type: @predictive_board&.board_type,
  #     # position: [bi_layout["x"], bi_layout["y"]],
  #     # part_of_speech: bi.data["part_of_speech"] || bi.image.part_of_speech,
  #     # frequency: bi_data_for_screen["frequency"] || "low",
  #     }
  #     existing_layout << w
  #   end

  #   max_num_of_rows = (board_images_count / num_of_columns.to_f).ceil
  #   response = OpenAiClient.new({}).generate_formatted_board(name, num_of_columns, existing_layout, max_num_of_rows, maintain_existing_layout)
  #   if response
  #     parsed_response = response.gsub("```json", "").gsub("```", "").strip
  #     if valid_json?(parsed_response)
  #       parsed_response = JSON.parse(parsed_response)
  #     else
  #       parsed_response = transform_into_json(parsed_response)
  #     end
  #     # parsed_response = JSON.parse(response)
  #     grid_response = parsed_response["grid"]
  #     if parsed_response["personable_explanation"]
  #       personable_explanation = "Personable Explanation: " + parsed_response["personable_explanation"]
  #     end
  #     if parsed_response["professional_explanation"]
  #       professional_explanation = "Professional Explanation: " + parsed_response["professional_explanation"]
  #     end
  #     if personable_explanation && professional_explanation
  #       explanation = personable_explanation + "\n" + professional_explanation
  #       self.data["personable_explanation"] = personable_explanation
  #       self.data["professional_explanation"] = professional_explanation
  #     end

  #     if grid_response.blank?
  #       Rails.logger.debug "No grid response"
  #       return
  #     end

  #     grid_response.each_with_index do |item, index|
  #       label = item["word"]
  #       board_image = @board_images.joins(:image).find_by(images: { label: label })
  #       image = board_image&.image

  #       if board_image
  #         item["size"] ||= [1, 1]
  #         # if item["frequency"].present?
  #         #   if item["frequency"] === "high"
  #         #     item["size"] = [2, 2]
  #         #   end
  #         # end

  #         board_image.data["label"] = label
  #         board_image.data[screen_size] ||= {}
  #         board_image.data[screen_size]["frequency"] = item["frequency"]
  #         board_image.data[screen_size]["size"] = item["size"]
  #         board_image.data["part_of_speech"] = item["part_of_speech"]
  #         board_image.data["bg_color"] = image.background_color_for(item["part_of_speech"])

  #         board_image.position = index
  #         board_image.save!

  #         image.part_of_speech = item["part_of_speech"] if item["part_of_speech"].present? && image.part_of_speech.blank?
  #         image.save!

  #         x_coordinate = item["position"][0]
  #         y_coordinate = item["position"][1]
  #         if x_coordinate >= num_of_columns
  #           x_coordinate = 0
  #         end
  #         # max_num_of_rows = (images.count / num_of_columns.to_f).ceil
  #         if y_coordinate >= max_num_of_rows
  #           y_coordinate = max_num_of_rows
  #         end

  #         board_image.layout ||= {}
  #         board_image.layout[screen_size] = { "x" => x_coordinate, "y" => y_coordinate, "w" => item["size"][0], "h" => item["size"][1], "i" => board_image.id.to_s }
  #         board_image.save!
  #       else
  #         Rails.logger.debug "Board Image not found for label: #{label}"
  #       end
  #     end
  #     if explanation
  #       self.description = explanation
  #       self.save!
  #     end
  #   end
  #   self
  # end

  def format_board_with_ai(screen_size: "lg", maintain_existing_layout: false)
    columns = get_number_of_columns(screen_size)
    images = board_images.includes(:image).to_a
    rows = (images.size / columns.to_f).ceil

    existing = images.map do |bi|
      layout = (bi.layout || {}).dig(screen_size) || {}
      {
        word: bi.label,
        size: [layout["w"], layout["h"]].compact.presence || [1, 1],
        board_type: bi.predictive_board_id ? Board.find_by(id: bi.predictive_board_id)&.board_type : nil,
      }
    end

    payload = AiBoardFormatter.call(
      name: name,
      columns: columns,
      rows: rows,
      existing: existing,
      maintain_existing: maintain_existing_layout,
    )

    return self if payload.blank?

    grid = payload["grid"].to_a
    by_label = images.index_by { |bi| bi.label.to_s.downcase }

    ActiveRecord::Base.transaction do
      grid.each_with_index do |item, idx|
        label = item["word"].to_s
        bi = by_label[label.downcase]
        next unless bi

        pos = Array(item["position"] || [0, 0])
        size = Array(item["size"] || [1, 1])
        x = pos[0].to_i.clamp(0, columns - 1)
        y = pos[1].to_i.clamp(0, [rows - 1, 0].max)

        bi.data["label"] = label
        bi.data[screen_size] ||= {}
        bi.data[screen_size]["frequency"] = item["frequency"]
        bi.data[screen_size]["size"] = size
        bi.data["part_of_speech"] = item["part_of_speech"]
        bi.data["bg_color"] = bi.image.background_color_for(item["part_of_speech"])

        bi.position = idx
        bi.layout ||= {}
        bi.layout[screen_size] = { "x" => x, "y" => y, "w" => size[0], "h" => size[1], "i" => bi.id.to_s }
        bi.save!

        if item["part_of_speech"].present? && bi.image.part_of_speech.blank?
          bi.image.update!(part_of_speech: item["part_of_speech"])
        end
      end

      # optional explanations
      personable = payload["personable_explanation"].presence
      professional = payload["professional_explanation"].presence

      if personable || professional
        self.data["personable_explanation"] = "#{personable}" if personable
        self.data["professional_explanation"] = "#{professional}" if professional
        self.description = [self.data["personable_explanation"], self.data["professional_explanation"]].compact.join("\n") if description.blank?
        save!
      end
    end

    self
  end

  def tmp_board_type
    case resource_type
    when "category"
      return "category"
    when "Image"
      if parent_type == "PredefinedResource"
        return "category"
      else
        return "predictive"
      end
    when "Board"
      return "dynamic"
    when "User"
      return "static"
    when "Menu"
      return "menu"
    when "OpenaiPrompt"
      return "scenario"
    else
      return resource_type.downcase
    end
  end

  def root_board
    self
  end

  def preset_display_image_url
    return settings["preset_display_image_url"] if settings && !settings["preset_display_image_url"].blank?
    display_image_url
  end

  def update_preset_display_image_url(url = nil)
    if url.blank?
      url = display_image_url
    end
    self.settings ||= {}
    if settings["preset_display_image_url"] == url
      return
    end
    if url.blank?
      Rails.logger.error "No URL provided for preset_display_image_url"
      return
    end
    self.settings["preset_display_image_url"] = url
    save
  end

  def is_frozen?
    return false unless settings
    settings["freeze_board"] == true
  end

  def public_url
    base_url = ENV["FRONT_END_URL"] || "http://localhost:8100"
    "#{base_url}/public-board/#{slug}"
  end

  def featured
    predefined && favorite
  end

  def api_view_with_predictive_images(viewing_user = nil, communicator_account = nil, show_hidden = false)
    @viewer_settings = viewing_user&.settings || {}
    is_a_user = viewing_user.class == "User"
    @board_settings = settings || {}
    unless show_hidden
      @board_images = visible_board_images.includes({ image: [:docs, :audio_files_attachments, :audio_files_blobs, :predictive_boards, :category_boards] }, :predictive_board).distinct
    else
      @board_images = visible_board_images.includes({ image: [:docs, :audio_files_attachments, :audio_files_blobs, :predictive_boards, :category_boards] }, :predictive_board).distinct
    end
    # @board_images = board_images.where(hidden: false)
    word_data = get_commons_words
    existing_words = word_data[:existing_words]
    missing_common_words = word_data[:missing_common_words]
    @root_board = root_board
    same_user = viewing_user && user_id == viewing_user.id
    can_edit = same_user || viewing_user&.admin?
    @matching_viewer_images = matching_viewer_images(viewing_user)
    if communicator_account
      can_edit = communicator_account.settings["can_edit_boards"] == true
    end
    {
      id: id,
      board_type: board_type,
      public_url: public_url,
      board_groups: board_groups,
      slug: slug,
      source_type: source_type,
      vendor: vendor,
      week_chart: week_chart,
      menu_id: board_type === "menu" ? parent_id : nil,
      name: name,
      root_board: @root_board,
      language: language,
      missing_common_words: missing_common_words,
      existing_words: existing_words,
      word_list: current_word_list,
      description: description,
      featured: featured,
      can_edit: can_edit,
      category: category,
      parent_type: parent_type,
      parent_id: parent_id,
      vendor_id: vendor_id,
      obf_id: obf_id,
      image_count: board_images_count,
      image_parent_id: image_parent_id,
      parent_description: parent_type === "User" ? "User" : parent&.to_s,
      menu_description: parent_type === "Menu" ? parent&.description : nil,
      parent_prompt: parent_type === "OpenaiPrompt" ? parent.prompt_text : nil,
      predefined: predefined,
      favorite: favorite,
      published: published,
      number_of_columns: number_of_columns,
      small_screen_columns: small_screen_columns,
      medium_screen_columns: medium_screen_columns,
      large_screen_columns: large_screen_columns,
      large_screen_rows: rows_for_screen_size("lg"),
      medium_screen_rows: rows_for_screen_size("md"),
      small_screen_rows: rows_for_screen_size("sm"),
      status: status,
      token_limit: token_limit,
      cost: cost,
      audio_url: audio_url,
      display_image_url: display_image_url || preset_display_image_url,
      # floating_words: words,
      common_words: Board.common_words,
      user_id: user_id,
      voice: voice,
      data: data,
      created_at: created_at,
      updated_at: updated_at,
      margin_settings: margin_settings,
      settings: settings,
      has_generating_images: has_generating_images?,
      current_user_teams: [],
      hello: "world",

      matching_viewer_images: is_a_user ? @matching_viewer_images.map { |i| i.api_view(viewing_user) } : [],
      images: @board_images.map do |board_image|
        @board_image = board_image

        @label = @board_image.label

        image = board_image.image

        is_owner = viewing_user && image.user_id == viewing_user&.id
        is_admin_image = [User::DEFAULT_ADMIN_ID, nil].include?(user_id)

        @predictive_board_id = @board_image.predictive_board_id
        @predictive_board = @board_image.predictive_board

        @viewer_settings = viewing_user&.settings || {}
        @predictive_board_settings = @predictive_board&.settings || {}

        @user_custom_default_id = @viewer_settings["opening_board_id"]

        is_dynamic = @board_image.is_dynamic?
        is_predictive = image.predictive?
        if @board_image.predictive_board_id == @root_board&.id
          is_dynamic = false
        end

        is_category = @predictive_board && @predictive_board.board_type == "category"
        freeze_board = @predictive_board_settings["freeze_board"] == true
        is_first_image = @board_image.position == 0
        freeze_parent_board = @board_settings["freeze_board"] == true
        @board_image.data ||= {}
        mute_name = @board_image.data["mute_name"] == true
        {
          id: image.id,
          label: @board_image.label,
          display_label: @board_image.display_label,
          hidden: @board_image.hidden,
          root_board_id: @root_board&.id,
          root_board_name: @root_board&.name,
          image_user_id: image.user_id,
          predictive_board_id: is_dynamic ? @predictive_board_id : @user_custom_default_id,
          user_custom_default_id: @user_custom_default_id,
          predictive_board_board_type: @predictive_board&.board_type,
          is_owner: is_owner,
          is_category: is_category,
          is_admin_image: is_admin_image,
          freeze_board: freeze_board,
          freeze_parent_board: freeze_parent_board,
          is_first_image: is_first_image,
          override_frozen: @board_image.override_frozen,
          position: @board_image.position,
          dynamic: is_dynamic,
          is_predictive: is_predictive,
          board_image_id: @board_image.id,
          image_prompt: @board_image.image_prompt,
          bg_color: @board_image.bg_color,
          bg_class: @board_image.bg_class,
          text_color: @board_image.text_color,
          next_words: @board_image.next_words,
          position: @board_image.position,
          src_url: @board_image.display_image_url || image.src_url,
          mute_name: mute_name,
          # src: image.src_url || @board_image.display_image_url || image.display_image_url(viewing_user),
          src: @board_image.display_image_url || image.display_image_url(viewing_user),
          display_image_url: @board_image.display_image_url,
          audio_url: @board_image.audio_url,
          audio: @board_image.audio_url || image.audio_url,
          voice: @board_image.voice,
          layout: @board_image.layout.with_indifferent_access,
          added_at: @board_image.added_at,
          part_of_speech: image.part_of_speech,
          data: @board_image.data,
          status: @board_image.status,
        }
      end,
      layout: print_grid_layout,
    }
  end

  def api_view_with_images(viewing_user = nil)
    api_view_with_predictive_images(viewing_user)
  end

  def personable_explanation
    return unless data
    data["personable_explanation"]
  end

  def professional_explanation
    return unless data
    data["professional_explanation"]
  end

  def rows_for_screen_size(screen_size = "sm")
    layout = self.layout[screen_size] || []
    number_of_rows = 0
    begin
      layout.each do |l|
        y = l["y"]
        h = l["h"]
        number_of_rows = y + h if y + h > number_of_rows
      end
    rescue => e
      # Rails.logger.error "Error getting rows for screen size: #{e}"
    end

    number_of_rows
  end

  def large_screen_rows
    rows_for_screen_size("lg")
  end

  def medium_screen_rows
    rows_for_screen_size("md")
  end

  def small_screen_rows
    rows_for_screen_size("sm")
  end

  def grid_info
    "Large Screen: #{large_screen_columns}x#{large_screen_rows} | Medium Screen: #{medium_screen_columns}x#{medium_screen_rows} | Small Screen: #{small_screen_columns}x#{small_screen_rows}"
  end

  def word_tree
    @buttons = []
    @board_images = board_images.includes(predictive_board: :board_images).order(:position)
    @board_images.each do |bi|
      image = bi.image
      if dynamic?
        @predictive_board_id = bi.predictive_board_id
        @predictive_board = @predictive_board_id ? Board.find_by(id: @predictive_board_id) : nil
        @predictive_images = @predictive_board&.board_images&.order(:position) || []
      end
      button = {
        label: bi.label,
      # image_id: bi.id,
      # predictive_images: @predictive_images.map { |pi| { label: pi.label, image_id: pi.id } },
      # predictive_board_id: @predictive_board_id,
      # audio_url: bi.audio_url,
      # src: bi.display_image_url,
      # layout: bi.layout,
      # part_of_speech: image.part_of_speech,
      }
      if @predictive_images&.any?
        button[:button_type] = @predictive_board.board_type
        button[:predictive_images] = @predictive_images.map(&:label)
      else
        button[:button_type] = "static"
      end
      @buttons << button
    end
    @buttons
  end

  def to_obf_tmp(screen_size = "lg")
    @board_images = board_images.with_artifacts.order(:position)
    obf_data = {}
    obf_
    obf_data["name"] = name
    # obf_data["description"] = description
    obf_data["board_type"] = board_type
    obf_data["images"] = @board_images.map do |bi|
      image = bi.image
      {
        label: bi.label,
        src: bi.display_image_url,
        audio: bi.audio_url,
        part_of_speech: image.part_of_speech,
        layout: bi.layout[screen_size],
      }
    end
    obf_data
  end

  def self.create_from_obf(obf_data, user_id)
    obf_data = obf_data.with_indifferent_access
    user = User.find(user_id)
    @board = Board.create!(name: obf_data["name"], board_type: "dynamic", user_id: user_id, parent_type: "User", parent_id: user_id)
    obf_data["images"].each do |image_data|
      image_data = image_data.with_indifferent_access
      @image = Image.searchable.where(user_id: @board.user_id).find_by(label: image_data["label"])
      @image = Image.create(label: image_data["label"]) unless @image
      new_board_image = @board.add_image(@image.id)
      if image_data["predictive_images"]&.any?
        @predictive_board = Board.create!(name: @image.label, board_type: "predictive", user_id: user_id, parent_type: "Image", parent_id: @image.id)
        image_data["predictive_images"].each do |predictive_image_label|
          @predictive_image = Image.searchable.where(user_id: @board.user_id).find_by(label: predictive_image_label)
          @predictive_image = Image.create(label: predictive_image_label) unless @predictive_image
          @predictive_board.add_image(@predictive_image.id) if @predictive_image
        end
        new_board_image.predictive_board_id = @predictive_board&.id
        new_board_image.save!
      end
    end
    @board
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      user_name: user.to_s,
      name: name,
      can_edit: user_id == viewing_user&.id || viewing_user&.admin?,
      layout: layout,
      audio_url: audio_url,
      group_layout: group_layout,
      position: position,
      data: data,
      ionic_icon: ionic_icon,
      large_screen_columns: large_screen_columns,
      medium_screen_columns: medium_screen_columns,
      small_screen_columns: small_screen_columns,
      large_screen_rows: rows_for_screen_size("lg"),
      medium_screen_rows: rows_for_screen_size("md"),
      small_screen_rows: rows_for_screen_size("sm"),
      personable_explanation: personable_explanation,
      professional_explanation: professional_explanation,
      description: description,
      parent_type: parent_type,
      predefined: predefined,
      number_of_columns: number_of_columns,
      status: status,
      token_limit: token_limit,
      cost: cost,
      display_image_url: display_image_url,
      board_type: board_type,
      user_id: user_id,
      voice: voice,
      word_list: data ? data["current_word_list"] : nil,
      settings: settings,
      margin_settings: margin_settings,
      preset_display_image_url: preset_display_image_url,
      board_images_count: board_images_count,
      obf_id: obf_id,
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  def word_sample
    current_word_list ? current_word_list.join(", ").truncate(150) : nil
  end

  def user_api_view(viewing_user = nil)
    data = self.data || {}
    {
      id: id,
      name: name,
      board_type: board_type,
      # image_count: board_images_count,
      can_edit: user_id == viewing_user&.id || viewing_user&.admin?,
      display_image_url: display_image_url,
      word_sample: word_sample,
      word_list: data["current_word_list"],
      created_at: created_at,
      updated_at: updated_at,
      voice: voice,
    }
  end

  def matching_image
    normalized_name = name.downcase.strip
    image = Image.find_by(label: normalized_name, user_id: user_id)
    image = Image.find_by(label: normalized_name, user_id: [User::DEFAULT_ADMIN_ID, nil]) unless image
    image
  end

  def create_matching_image
    normalized_name = name.downcase.strip
    image = Image.create(label: normalized_name, user_id: user_id)
    image
  end

  def matching_viewer_images(viewing_user = nil)
    viewing_user ||= user
    if viewing_user
      viewing_user.images.where("lower(label) = ?", name.downcase).order(label: :asc)
      # Board.where(name: label, user_id: viewing_user.id).order(created_at: :desc)
    else
      Image.where("lower(label) = ?", name.downcase).where(user_id: User::DEFAULT_ADMIN_ID, predefined: true).order(label: :asc)
    end
  end

  def assign_parent
    current_user ||= user
    if board_type == "predictive"
      self.parent_type = "Image"
      matching_image = self.user.images.find_or_create_by!(label: self.name, image_type: "predictive")
      if matching_image
        self.parent_id = matching_image.id
        self.image_parent_id = matching_image.id
      end
    elsif board_type == "category"
      matching_image = self.user.images.find_or_create_by!(label: self.name, image_type: "category")
      self.image_parent_id = matching_image.id if matching_image
      self.parent_id = matching_image.id if matching_image
      self.parent_type = "Image" if matching_image
    elsif board_type == "static"
      self.parent_type = "User"
      self.parent_id = user.id
    elsif board_type == "dynamic"
      self.parent_type = "User"
      self.parent_id = user.id
    else
      self.board_type = "static"
      self.parent_type = "User"
      self.parent_id = user.id
    end
  end

  def get_description
    response = OpenAiClient.new({}).get_board_description(self)
    if response
      if response[:content].blank?
        Rails.logger.error "*** ERROR - get_description *** \nDid not receive valid response. Response: #{response}\n"
        return
      end
      description = response[:content]
      description = description.gsub("```html", "").gsub("```", "").strip
      self.description = description
      self.save!
    end
  end

  def get_words(name_to_send, number_of_words, words_to_exclude = [], use_preview_model = false)
    words_to_exclude = board_images.pluck(:label).map { |w| w.downcase }
    response = OpenAiClient.new({}).get_additional_words(self, name_to_send, number_of_words, words_to_exclude, use_preview_model, language)
    begin
      if response
        if response[:content].blank?
          Rails.logger.error "*** ERROR - get_words *** \nDid not receive valid response. Response: #{response}\n"
          return
        end
        words = response[:content].gsub("```json", "").gsub("```", "").strip
        if words.blank? || words.include?("NO ADDITIONAL WORDS")
          return
        end
        if valid_json?(words)
          words = JSON.parse(words)
        else
          start_index = words.index("{")
          end_index = words.rindex("}")
          words = words[start_index..end_index]
          words = transform_into_json(words)
        end
      else
        Rails.logger.error "*** ERROR - get_words *** \nDid not receive valid response. Response: #{response}\n"
      end
      words_to_include = words["additional_words"] || []
      words_to_include = words_to_include.map { |w| w.downcase }
      words_to_include = words_to_include - words_to_exclude
      words_to_include = words_to_include.uniq
      words_to_include
    rescue => e
      Rails.logger.error "Error getting words: #{e}"
    end
  end

  def get_word_suggestions(name_to_use, number_of_words, words_to_exclude = [])
    response = OpenAiClient.new({}).get_word_suggestions(name_to_use, number_of_words, words_to_exclude)
    begin
      if response
        word_suggestions = response[:content].gsub("```json", "").gsub("```", "").strip
        if word_suggestions.blank? || word_suggestions.include?("NO WORDS")
          return
        end
        if valid_json?(word_suggestions)
          word_suggestions = JSON.parse(word_suggestions)
        else
          start_index = word_suggestions.index("{")
          end_index = word_suggestions.rindex("}")
          word_suggestions = word_suggestions[start_index..end_index]
          word_suggestions = transform_into_json(word_suggestions)
        end
      else
        Rails.logger.error "*** ERROR - get_word_suggestions *** \nDid not receive valid response. Response: #{response}\n"
      end
      word_suggestions["words"]
    rescue => e
      Rails.logger.error "Error getting word suggestions: #{e}"
    end
  end

  def self.determine_board_type(dynamic_images, is_root = false)
    return "static" unless dynamic_images
    return "dynamic" if is_root
    return "category"
  end

  def self.from_obf(data, current_user, board_group = nil)
    if board_group
      root_board_id = board_group.original_obf_root_id
    else
      root_board_id = nil
    end
    begin
      screen_size = "lg"
      dynamic_data = {}
      if data.is_a?(String)
        # Do nothing
      elsif data.is_a?(Pathname)
        data = data.read
      end

      obj = JSON.parse(data)
      Rails.logger.debug "Importing OBF: #{obj["name"]} - #{obj["id"]} -root_board_id: #{root_board_id}"
      board_name = obj["name"]
      obf_id = obj["id"]
      voice = obj["voice"] || "alloy"
      columns = obj["grid"]["columns"]
      large_screen_columns = columns
      medium_screen_columns = columns
      small_screen_columns = columns
      number_of_columns = columns
      board_data = { obf_grid: obj["grid"] }
      is_root = root_board_id == obf_id

      board = Board.find_by(name: board_name, user_id: current_user.id, obf_id: obf_id)

      dynamic_images = obj["buttons"].select { |item| item["load_board"] != nil }
      board_type = determine_board_type(dynamic_images, is_root)

      Rails.logger.debug "NAme: #{board_name} -- Board Type: #{board_type} - is_root: #{is_root} - dynamic_images: #{dynamic_images.count} - buttons: #{obj["buttons"].count}"

      board = Board.new(name: board_name, user_id: current_user.id, voice: voice,
                        large_screen_columns: large_screen_columns, medium_screen_columns: medium_screen_columns, small_screen_columns: small_screen_columns,
                        data: board_data, number_of_columns: number_of_columns, obf_id: obf_id) unless board
      board.board_type = board_type

      if board_group
        board_group.add_board(board)
      end

      board.assign_parent
      unless board.save!
        Rails.logger.warn "Board not saved"
        return
      end
      if is_root
        Rails.logger.debug "Root board found: #{board_name}"
        board_group.update(root_board_id: board.id)
      end
      grid = obj["grid"]
      if grid
        rows = grid["rows"]
        columns = grid["columns"]
        grid_order = grid["order"]
      end

      temp_display_image = nil
      Rails.logger.debug "Importing images for board: #{board.name}"
      (obj["buttons"] || []).each do |item|
        label = item["label"]
        if item["ext_saw_image_id"]
          image = Image.find_by(id: item["ext_saw_image_id"].to_i, user_id: current_user.id)
        end
        image = Image.find_by(user_id: current_user.id) unless image
        found_image = image
        # image = Image.find_by(obf_id: item["image_id"], user_id: [User::DEFAULT_ADMIN_ID, nil]) unless image
        # image = Image.static.public_img.find_by(label: label, user_id: [User::DEFAULT_ADMIN_ID, nil]) unless image
        image = Image.new(label: label, user_id: current_user.id) unless image
        image.clean_up_label
        image.save!

        if !image
          Rails.logger.error "Image not found for label: #{label}"
          next
        end

        doc = obj["images"].detect { |s| s["id"] == item["image_id"] }

        grid_coordinates = nil
        if grid_order
          grid_order.each_with_index do |row, y|
            row.each_with_index do |cell, x|
              if cell.blank?
                next
              end
              if cell == item["id"]
                grid_coordinates = [x, y]
              end
            end
          end
        end
        if doc
          url = doc["url"]
          doc_data = doc["data"]

          file_format = doc["content_type"] || "image/png"
          file_format = "image/svg+xml" if file_format == "image/svg"
          license = doc["license"]
          raw_txt = "obf_id_#{doc["id"]}"
          processed = "processed: #{Time.now}"
          if url
            temp_display_image = url
            if image.docs.where(original_image_url: url).none?
              downloaded_image = Down.download(url)
              user_id = current_user.id
              doc = image.docs.create!(raw: raw_txt, user_id: user_id, processed: processed, source_type: "ObfImport", original_image_url: url, license: license)
              doc.image.attach(io: downloaded_image, filename: "img_#{image.label_for_filename}_#{image.id}_doc_#{doc.id}.#{doc.extension}", content_type: file_format) if downloaded_image
              image.update(status: "finished")
            end
          elsif doc_data
            data = Base64.decode64(doc_data)
            user_id = current_user.id
            Rails.logger.debug "Attaching image - file_format: #{file_format}"
            doc = image.docs.create!(raw: raw_txt, user_id: user_id, processed: processed, source_type: "ObfImport", original_image_url: url, license: license)
            doc.image.attach(data: doc_data, filename: "img_#{image.label_for_filename}_#{image.id}_doc_#{doc.id}.#{doc.extension}", content_type: file_format) if data
            unless doc.save
              Rails.logger.error "Error saving doc: #{doc.errors.full_messages}"
            end
            doc.reload
            temp_display_image = doc.display_url
            image.update(status: "finished")
          else
            Rails.logger.debug "No URL or path found for image"
          end
        end

        dynamic_board = item["load_board"]

        existing_image = board.board_images.find_by(image_id: image.id)
        if existing_image
          new_board_image = existing_image
        else
          new_board_image = board.board_images.create!(image_id: image.id.to_i, voice: board.voice, position: board.board_images_count, display_image_url: temp_display_image)
        end
        if new_board_image
          new_board_image_layout = { "x" => grid_coordinates[0], "y" => grid_coordinates[1], "w" => 1, "h" => 1, "i" => new_board_image.id.to_s }
          new_board_image.layout["lg"] = new_board_image_layout
          new_board_image.layout["md"] = new_board_image_layout
          new_board_image.layout["sm"] = new_board_image_layout

          new_board_image.data ||= {}
          new_board_image.data["obf_id"] = item["image_id"]

          new_board_image.save!
        end
        dynamic_data[image.id] = { "board_id" => board.id,
                                   "board" => board,
                                   "original_obf_id" => obj["id"],
                                   "dynamic_board" => dynamic_board,
                                   "label" => label,
                                   "orginal_image_id" => item["image_id"],
                                   "board_image_id" => new_board_image.id }
      end
      board.update!(display_image_url: temp_display_image) if temp_display_image

      return [board, dynamic_data]
    rescue => e
      Rails.logger.error "Error Importing from OBF: #{e}"
      return nil
    end
  end

  def source_type
    data = self.data || {}
    data["source_type"] || nil
  end

  def parse_obf_grid(obf_grid)
    # Extract rows, columns, and order from the OBF grid
    rows = obf_grid["rows"]
    columns = obf_grid["columns"]
    order = obf_grid["order"]

    # Reconstruct the original grid layout
    original_grid = []
    order.each_with_index do |row, y|
      row.each_with_index do |cell, x|
        next if cell.nil? # Skip empty cells
        original_grid << {
          "x" => x,
          "y" => y,
          "w" => 1, # Assuming each cell is 1x1 in size; adjust if needed
          "h" => 1, # Assuming each cell is 1x1 in size; adjust if needed
          "i" => cell,
        }
      end
    end
    original_grid
  end

  def self.from_obz(extracted_obz_data, current_user, group_name = nil, root_board_id = nil)
    extracted_obz_data = extracted_obz_data.with_indifferent_access
    manifest = extracted_obz_data[:manifest]
    boards = extracted_obz_data[:boards]
    group_name ||= boards[0]["name"]
    Rails.logger.debug "Creating board group: #{group_name} - root_board_id: #{root_board_id}"

    board_group = BoardGroup.create!(name: group_name, user_id: current_user.id, original_obf_root_id: root_board_id)

    created_boards = []
    dynamic_data_array = []
    boards.each_with_index do |board_data, index|
      board_json = board_data.to_json
      new_board, dynamic_data = from_obf(board_json, current_user, board_group)
      if !new_board
        Rails.logger.error "Error creating board from OBF - #{board_data["name"]}"
        next
      end
      created_boards << { board_id: new_board&.id, original_obf_id: board_data["id"], board: new_board }
      dynamic_data_array << dynamic_data
      if new_board
        Rails.logger.debug "Adding board to board group #{board_group.id} - #{new_board.name}"
        new_board.board_groups << board_group
        new_board.save!
      else
        Rails.logger.error "Error creating board from OBF"
      end
    end

    if created_boards.empty?
      Rails.logger.error "No boards created"
      return
    end

    Rails.logger.debug ">>>> root_board_id: #{root_board_id}"
    board_group.reload

    if root_board_id
      root_board = board_group.root_board
      Rails.logger.debug "Root board found - group: #{group_name} - #{root_board.name}" if root_board
      Rails.logger.debug "Root board not found - group: #{group_name}" unless root_board
    else
      Rails.logger.debug "Root board not found: #{root_board_id} - group: #{group_name}"
      root_board = board_group.boards.order(:position).first
    end
    Rails.logger.debug "Root board: #{root_board&.name} - Updating board type to dynamic" if root_board
    board_group.update!(root_board_id: root_board&.id) if root_board
    root_board.update!(board_type: "dynamic") if root_board
    if !root_board
      Rails.logger.error ">>>> Root board not found - group: #{group_name}"
    end

    dynamic_data_array.each do |dynamic_data|
      dynamic_data&.each do |image_id, data|
        image = Image.find_by(id: image_id&.to_i, user_id: current_user.id)
        board_image_id = data["board_image_id"]
        board_image = BoardImage.find_by(id: board_image_id)
        next unless board_image
        if board_image
          if data["dynamic_board"]
            if created_boards.any? { |b| b[:original_obf_id] == data["dynamic_board"]["id"] }
              dynamic_board = created_boards.find { |b| b[:original_obf_id] == data["dynamic_board"]["id"] }
              dynamic_board_id = dynamic_board.with_indifferent_access[:board_id]
              Rails.logger.debug "Setting predictive board for image: #{board_image.label} - #{dynamic_board_id}"
              # image.predictive_board_id = dynamic_board_id
              board_image.predictive_board_id = dynamic_board_id

              board_image.save!
            else
              board_image.predictive_board_id = root_board.id if root_board
              # image.image_type = "predictive"
              board_image.save!
            end
          end
        else
          Rails.logger.warn "board_image not found for id: #{board_image_id}"
        end
      end
    end

    created_boards
  end

  def self.extract_manifest(zip_path, manifest_filename = "manifest.json")
    Zip::File.open(zip_path) do |zip_file|
      manifest_entry = zip_file.find_entry(manifest_filename)

      raise "Manifest file '#{manifest_filename}' not found in the archive" unless manifest_entry

      manifest_entry.get_input_stream.read
    end
  rescue Zip::Error => e
    Rails.logger.debug "Failed to process the ZIP file: #{e.message}"
    nil
  end

  def self.analyze_manifest(manifest_data)
    manifest_data = JSON.parse(manifest_data)
    parsed_data = manifest_data.with_indifferent_access
    root_board_id = parsed_data[:root]
    data = parsed_data[:paths]
    pp data.keys
    boards = data[:boards]
    buttons = data[:buttons]
    images = data[:images]
    sounds = data[:sounds]
    first_image = images&.first
    {
      board_count: boards&.count,
      button_count: buttons&.count,
      image_count: images&.count,
      sound_count: sounds&.count,
      root_board_id: root_board_id,
    }
  rescue JSON::ParserError => e
    Rails.logger.debug "Failed to parse the manifest data: #{e.message}"
    nil
  end
end
