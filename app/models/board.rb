# == Schema Information
#
# Table name: boards
#
#  id                         :bigint           not null, primary key
#  user_id                    :bigint
#  name                       :string
#  parent_type                :string           not null
#  parent_id                  :bigint           not null
#  description                :text
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#  cost                       :integer          default(0)
#  predefined                 :boolean          default(FALSE)
#  token_limit                :integer          default(0)
#  voice                      :string
#  status                     :string           default("pending")
#  number_of_columns          :integer          default(6)
#  small_screen_columns       :integer          default(3)
#  medium_screen_columns      :integer          default(8)
#  large_screen_columns       :integer          default(12)
#  display_image_url          :string
#  layout                     :jsonb
#  position                   :integer
#  audio_url                  :string
#  bg_color                   :string
#  margin_settings            :jsonb
#  settings                   :jsonb
#  category                   :string
#  data                       :jsonb
#  group_layout               :jsonb
#  image_parent_id            :integer
#  board_type                 :string
#  obf_id                     :string
#  language                   :string           default("en")
#  board_images_count         :integer          default(0), not null
#  published                  :boolean          default(FALSE)
#  favorite                   :boolean          default(FALSE)
#  vendor_id                  :bigint
#  slug                       :string           default("")
#  in_use                     :boolean          default(FALSE), not null
#  is_template                :boolean          default(FALSE), not null
#  board_screenshot_import_id :bigint
#  sub_board                  :boolean          default(TRUE), not null
#  generated_token            :string
#  generated_token_expires_at :datetime
#  metadata                   :jsonb
#  tags                       :string           default([]), not null, is an Array
#
require "zip"

class Board < ApplicationRecord
  TILE_VARIANT_TRANSFORMATIONS = {
    resize_to_limit: [528, 528],
    format: :webp,
    saver: {
      quality: 65,
      strip: true,
    },
  }.freeze
  has_rich_text :display_description
  belongs_to :user, optional: true
  belongs_to :vendor, optional: true
  paginates_per 100
  belongs_to :parent, polymorphic: true, optional: true
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
  has_one_attached :preview_image
  has_one_attached :pdf_file
  has_many :child_boards, dependent: :destroy
  has_many :original_child_boards, class_name: "ChildBoard", foreign_key: "original_board_id", dependent: :nullify
  has_many :child_accounts, through: :child_boards
  belongs_to :image_parent, class_name: "Image", optional: true
  belongs_to :board_screenshot_import, class_name: "BoardScreenshotImport", optional: true
  has_many :word_events
  has_many :subgroups, class_name: "BoardGroup", foreign_key: "root_board_id", dependent: :nullify
  has_many :predictive_board_images, class_name: "BoardImage", foreign_key: "predictive_board_id", dependent: :nullify

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

  scope :for_user, ->(user) { where(user: user, is_template: false).or(where(user_id: User::DEFAULT_ADMIN_ID, predefined: true, is_template: false)) }
  scope :alphabetical, -> { order(Arel.sql("LOWER(name) ASC")) }
  scope :reverse_alphabetical, -> { order(Arel.sql("LOWER(name) DESC")) }
  scope :with_image_parent, -> { where.associated(:image_parent) }
  scope :searchable, -> { where.not(board_type: "menu").where(obf_id: nil) }
  scope :menus, -> { where(board_type: "menu").or(where(parent_type: "Menu")) }
  scope :non_menus, -> { where.not(board_type: "menu").where.not(parent_type: "Menu") }
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
  scope :generated, -> { where.not(generated_token: nil) }
  scope :created_before_this_week, -> { where("created_at < ?", 8.days.ago) }
  scope :created_today, -> { where("created_at > ?", 1.day.ago.end_of_day) }
  scope :created_yesterday, -> { where("created_at > ? AND created_at < ?", 1.day.ago.beginning_of_day, Time.zone.now.beginning_of_day) }
  scope :communikate_boards, -> { where("name ILIKE ?", "%CommuniKate%") }
  # Board Builder persists a linked tree (root + folder sub-boards). The
  # sub-boards are marked settings["builder_child"]=true so the whole tree
  # counts as ONE board against the user's limit (see User#countable_board_count).
  scope :not_builder_child, -> { where("NOT COALESCE((settings->>'builder_child')::boolean, false)") }

  scope :including_images, -> { includes(board_images: :image) }
  scope :public_boards, -> { where(user_id: User::DEFAULT_ADMIN_ID, predefined: true, published: true).where.not(parent_type: "Menu").where(obf_id: nil) }
  scope :public_menu_boards, -> { where(user_id: User::DEFAULT_ADMIN_ID, predefined: true, published: true, parent_type: "Menu") }
  scope :without_preset_display_image, -> { where.missing(:preset_display_image_attachment) }
  scope :preset, -> { where(predefined: true) }
  scope :welcome, -> { where(category: "welcome", predefined: true) }
  scope :published, -> { where(published: true) }
  POSSIBLE_BOARD_TYPES = %w[board category user image menu].freeze

  scope :dynamic_defaults, -> { where(name: "Dynamic Default", parent_type: "PredefinedResource") }

  # scope :with_artifacts, -> { includes({ board_images: { image: [:docs, :audio_files_attachments, :audio_files_blobs] } }) }
  # scope :with_artifacts, -> { includes({ board_images: [{ image: [{ docs: [:image_attachment, :image_blob, :user_docs] }, :audio_files_attachments, :audio_files_blobs, :user] }] }, :image_parent, :preview_image_attachment, :preview_image_blob) }
  scope :with_artifacts, -> { includes(:board_images, :user, :preview_image_attachment, :preview_image_blob) }
  scope :in_use, -> { where(in_use: true) }
  scope :not_in_use, -> { main_boards.where(in_use: false) }
  scope :templates, -> { where(is_template: true) }
  scope :non_templates, -> { where(is_template: false) }
  scope :sub_boards, -> { where(sub_board: true) }
  scope :main_boards, -> { non_menus.where(sub_board: [false, nil]) }
  scope :newly_created, -> { main_boards.created_this_week.order(created_at: :desc) }
  scope :recent, -> { main_boards.where("updated_at > ?", 1.week.ago).order(updated_at: :desc) }

  scope :with_any_tags, ->(values) do
          tag_values = Array(values)
            .flat_map { |v| v.to_s.split(",") }
            .map { |tag| normalize_tag_value(tag) }
            .reject(&:blank?)
            .uniq

          tag_values.present? ? where("boards.tags && ARRAY[?]::varchar[]", tag_values) : all
        end

  scope :with_all_tags, ->(values) do
          tag_values = Array(values)
            .flat_map { |v| v.to_s.split(",") }
            .map { |tag| normalize_tag_value(tag) }
            .reject(&:blank?)
            .uniq

          tag_values.present? ? where("boards.tags @> ARRAY[?]::varchar[]", tag_values) : all
        end

  def self.normalize_tag_value(tag)
    tag.to_s.strip.downcase.gsub(/\s+/, " ")
  end

  def self.public_boards_tags
    Board.public_boards.distinct.pluck("unnest(tags)").compact.uniq # pluck all tags from public boards, remove nils, and return unique values
  end

  def self.myspeak_public_boards
    Board.public_boards.with_all_tags(["myspeak"])
  end

  SAFE_FILTERS = %w[all predefined user_made ai_generated predictive public_boards in_use published sub_boards main_boards recent newly_created not_in_use menus].freeze

  include ImageHelper

  before_save :set_voice, if: :voice_changed?
  before_save :set_default_voice, unless: :voice?
  # before_save :update_display_image, unless: :display_image_url?
  # before_save :update_preset_display_image_url, if: :display_image_url_changed?

  # before_save :set_board_type
  before_save :clean_up_name
  before_save :validate_data
  before_save :set_vendor_id
  before_save :check_in_use, unless: :is_a_menu?
  before_save :check_is_sub_board

  before_save :set_display_margin_settings, unless: :margin_settings_valid_for_all_screen_sizes?
  before_save :set_parent

  before_create :set_screen_sizes, :set_number_of_columns
  after_initialize :set_initial_layout, if: :layout_empty?
  after_update_commit :retranslate_on_language_change

  def retranslate_on_language_change
    return unless saved_change_to_language?
    schedule_translations_for(language)
  end

  def run_generate_preview_job
    GenerateBoardPreviewJob.perform_async(id, { "generate_png" => true, "hide_header" => true }) # Generate PNG preview without header
    # GenerateBoardPreviewJob.perform_async(id, { "generate_pdf" => true }) # PDF with header for sharing
  end

  def run_generate_preview_job_later
    GenerateBoardPreviewJob.perform_in(2.minutes, id, { "generate_png" => true, "hide_header" => true }) # Generate PNG preview without header
    # GenerateBoardPreviewJob.perform_in(2.minutes, id, { "generate_pdf" => true }) # PDF with header for sharing
  end

  def generate_preview(generate_png: false, generate_pdf: false, hide_header: true, screen_size: "lg")
    Boards::GeneratePreviewAssets.new(
      board: self,
      screen_size: screen_size,
      hide_header: hide_header,
      routes: Rails.application.routes.url_helpers,
    ).call(generate_png: generate_png, generate_pdf: generate_pdf)
  end

  def generate_previews
    generate_preview(generate_png: true, hide_header: true) # Generate PNG preview without header
    # generate_preview(generate_pdf: true) # PDF with header for sharing
  end

  # When `settings["display_follows_preview"]` is true, the board's
  # display image should track the live preview rather than a frozen
  # snapshot URL. Persisting *intent* sidesteps the stale `?v=` problem
  # that arises when callers store a previous `preview_image_url` string.
  def display_follows_preview?
    return false unless settings.is_a?(Hash)
    ActiveModel::Type::Boolean.new.cast(settings["display_follows_preview"]) == true
  end

  # Override the AR-generated getter so reads (including serializers) see
  # the live preview URL when the user has opted into "follow preview".
  # The setter is untouched — writes still go straight to the column.
  def display_image_url
    if display_follows_preview? && preview_image.attached?
      return preview_image_url
    end
    read_attribute(:display_image_url)
  end

  def preview_image_url
    return if !preview_image.attached?
    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      cdn_host = ENV["CDN_HOST"]
      if cdn_host
        # Key is deterministic (board_previews/<id>/preview.png) so the URL is
        # stable. Append `?v=<blob.created_at>` so clients and CloudFront pick
        # up the new PNG on regeneration — the service purges + reuploads, so
        # each regen mints a fresh blob row.
        "#{cdn_host}/#{preview_image.key}?v=#{preview_image.blob.created_at.to_i}"
      else
        preview_image.url # Fallback to the direct Active Storage URL
      end
    else
      preview_image.url
    end
  end

  def pdf_url
    return if !pdf_file.attached?
    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      cdn_host = ENV["CDN_HOST"]
      if cdn_host
        "#{cdn_host}/#{pdf_file.key}" # Construct CloudFront URL
      else
        pdf_file.url # Fallback to the direct Active Storage URL
      end
    else
      pdf_file.url
    end
  end

  def download_pdf_url
    Rails.application.routes.url_helpers.pdf_api_generated_board_url(self, host: ENV["API_URL"] || "localhost:4000")
  end

  def generated?
    generated_token.present?
  end

  def set_parent
    if parent_type.nil? && parent_id.nil?
      self.parent_type = "User"
      self.parent_id = user_id if user_id
      unless user_id
        Rails.logger.warn "Board #{id} has no user_id, setting parent_id to DEFAULT_ADMIN_ID"
        self.user_id = User::DEFAULT_ADMIN_ID
      end
    end
  end

  def public_board?
    user_id == User::DEFAULT_ADMIN_ID && predefined && published
  end

  # Whether `user` (may be nil for a logged-out visitor) is allowed to view this
  # board. Published boards are shareable to anyone; private boards are limited
  # to the owner, admins, and team members. Used to gate the unauthenticated
  # `boards#show` endpoint that backs the frontend `/pb/<slug>` route.
  def viewable_by?(user)
    return true if published?
    return false if user.nil?
    return true if user.admin?
    return true if user_id == user.id

    team_users.exists?(user_id: user.id)
  end

  def in_a_public_group?
    @in_a_public_group ||= board_group_boards.joins(:board_group).where(board_groups: { predefined: true }).exists?
  end

  attr_accessor :skip_broadcasting

  def text_color
    settings["text_color"] || "#000000"
  end

  def set_text_color(color)
    self.settings ||= {}
    self.settings["text_color"] = color
  end

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

  def parent_boards(viewing_user_id)
    unless viewing_user_id
      []
    end
    Board.joins(:board_images)
      .where(board_images: { predictive_board_id: id }, user_id: viewing_user_id, is_template: false)
      .where.not(id: id)
      # Preload the preview-image attachment so the serializer can build a
      # per-board thumbnail URL without an N+1 across parent boards.
      .with_attached_preview_image
      .distinct
  end

  def update_board_images_to_default_docs!
    board_images.includes(:image).find_each do |board_image|
      board_image.update_to_default_doc!
    end
  end

  def update_board_images_to_user_docs!
    images.includes(:board_images).find_each do |image|
      image.update_to_src_url!(user)
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

  def run_recategorization_job
    board_image_ids.each_slice(30) do |batch|
      puts "Scheduling recategorization for Board ID #{id} with BoardImage IDs #{batch.size}"
      RecategorizeImagesJob.perform_async("BoardImage", batch)
    end
  end

  def set_initial_layout
    self.layout = { "lg" => [], "md" => [], "sm" => [] }
  end

  def ionic_icon
    return "hash" if name&.downcase&.include?("numbers")
    return "handshake" if name&.downcase&.include?("greetings")
    return "expand" if name&.downcase&.include?("sizes")
    return "dice" if name&.downcase&.include?("little")
    return "happy" if name&.downcase&.include?("feelings")
    return "people" if name&.downcase&.include?("family")
    return "home" if name&.downcase&.include?("home page")
    return "shirt" if name&.downcase&.include?("daily routine")
    return "water" if name&.downcase&.include?("bathroom")
    return "bed" if name&.downcase&.include?("sleep")
    return "shirt" if name&.downcase&.include?("routine")

    "default"
  end

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
    self.data["personable_explanation"] = data["personable_explanation"].gsub("Personable Explanation: ", "") if data["personable_explanation"]
    self.data["professional_explanation"] = data["professional_explanation"].gsub("Professional Explanation: ", "") if data["professional_explanation"]
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

  def is_a_menu?
    parent_type_menu? || board_type == "menu"
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

  def update_display_image
    return if board_images.empty? || display_image_url.present?
    board_image = board_images.first
    if board_image
      self.display_image_url = board_image.display_image_url
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

  def add_tag(tag)
    normalized_tag = self.class.normalize_tag_value(tag)
    return if normalized_tag.blank?
    self.tags ||= []
    unless tags.include?(normalized_tag)
      self.tags << normalized_tag
    end
  end

  def remove_tag(tag)
    normalized_tag = self.class.normalize_tag_value(tag)
    return if normalized_tag.blank? || tags.blank?
    self.tags = tags.reject { |t| t == normalized_tag }
  end

  def check_in_use
    child_board_templates = ChildBoard.where(original_board_id: id)
    if child_board_templates.any?
      self.in_use = true
    elsif !child_board_templates.any?
      self.in_use = false
    end
  end

  IS_SUB_BOARD_TAG = "sub-board".freeze

  def check_is_sub_board
    parent_boards = parent_boards(user_id)
    if parent_boards.any?
      self.sub_board = true
      add_tag(IS_SUB_BOARD_TAG)
    elsif !parent_boards.any?
      self.sub_board = false
      remove_tag(IS_SUB_BOARD_TAG)
    end
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
      self.name = original_type_name
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
    parent&.resource_type || parent_type
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
    user_voice_settings = user&.settings["voice"] || {}
    user_voice = user_voice_settings.is_a?(Hash) ? user_voice_settings["name"] : nil
    user_voice = VoiceService.normalize_voice(user_voice) if user_voice
    self.voice = user_voice
  end

  def set_voice
    board_images.includes(:image).each do |bi|
      bi.update!(voice: voice) if bi.voice != voice

      bi.create_voice_audio
    end
    # sub_board_ids = board_images.pluck(:predictive_board_id).compact
    # if sub_board_ids.any?
    #   board_ids = Board.where(id: sub_board_ids, user_id: user_id).pluck(:id)
    #   Rails.logger.info "SET VOICE - Sub boards to update: #{board_ids.count} boards found for user_id #{user_id}"
    #   board_ids.each_slice(5) do |batch|
    #     UpdateBoardsVoiceJob.perform_async(batch, voice, language)
    #   end
    # end
  end

  def self.create_audio_for_scope(scope, limit = 10)
    count = 0
    scope.includes(board_images: :image).each do |board|
      board.board_images.find_in_batches(batch_size: 5) do |bi_batch|
        bi_batch.each do |bi|
          img = bi.image
          # img.create_audio_for_select_voices
          CreateAllAudioJob.perform_async(img.id, board.language, "select")
          count += 1

          sleep(1) # Add a small delay between starting jobs to avoid overwhelming the system
        end
        sleep(2) # Add a small delay between batches to avoid overwhelming the system
      end
      if count >= limit
        puts "Reached limit of #{limit} boards with audio created. Stopping."
        return
      end
    end
  end

  def create_audio_for_select_voices
    board_images.includes(:image).find_in_batches(batch_size: 5) do |bi_batch|
      bi_batch.each do |bi|
        img = bi.image
        img.start_select_voices_audio_job
      end
      sleep(1) # Add a small delay between batches to avoid overwhelming the system
    end
  end

  def create_audio_for_all_voices
    board_images.includes(:image).find_in_batches(batch_size: 5) do |bi_batch|
      bi_batch.each do |bi|
        img = bi.image
        img.start_create_all_audio_job
        sleep(0.5) # Add a small delay between starting jobs to avoid overwhelming the system
      end
      sleep(1) # Add a small delay between batches to avoid overwhelming the system
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

  def has_unprocessed_docs?
    unprocessed_docs.any?
  end

  def unprocessed_docs
    display_docs.select { |doc| doc.tile_variant_processed? == false }
  end

  def processed_docs
    display_docs.select { |doc| doc.tile_variant_processed? == true }
  end

  def display_docs
    images.map(&:display_doc).compact
  end

  def update_docs_to_default
    board_images.includes(:image).find_each do |bi|
      bi.update_to_default_doc!
    end
  end

  def unprocessed_display_docs
    display_docs.select { |doc| doc.tile_variant_processed? == false }
  end

  def process_unprocessed_docs
    unprocessed_doc_ids = unprocessed_display_docs.map(&:id)
    puts "Processing #{unprocessed_doc_ids.count} unprocessed docs for Board ID #{id}"
    sleep 3
    unprocessed_doc_ids.each_slice(10).with_index do |batch, index|
      PreprocessDocTileVariantsJob.perform_in((index + 1).minutes, batch)
    end
  end

  def image_docs_for_user(user = nil)
    user ||= self.user
    image_docs.select { |doc| doc.user_id == user.id }
  end

  def find_or_create_images_from_word_list(word_list)
    if id.blank?
      self.save!
    end
    unless word_list && word_list.any?
      return
    end
    if word_list.is_a?(String)
      word_list = word_list.split(" ")
    end
    if word_list.count > 100
      word_list = word_list[0..99]
    end
    image_ids_to_generate = []

    word_list.each do |word|
      og_word = word
      if word.length > 1
        word = word
      else
        if word.downcase == "i"
          word = "I"
        else
          word = word.downcase
        end
      end
      Rails.logger.debug "Change detected: #{og_word} -> #{word}" unless og_word == word
      image = user.images.find_by(label: word) if user_id

      image = Image.public_img.find_by(label: word, user_id: [User::DEFAULT_ADMIN_ID, nil]) unless image
      new_image = Image.create(label: word) unless image
      image ||= new_image
      display_doc = image.display_tile_url(user)
      if display_doc.blank?
        # image_prompt = "Create an image of #{word}"
        # image_prompt = image.default_image_prompt
        admin_image_present = image.docs.any? { |doc| doc.user_id == User::DEFAULT_ADMIN_ID }
        user_image_present = image.docs.any? { |doc| doc.user_id == user_id }
        image_ids_to_generate << image.id unless admin_image_present || user_image_present
      end
      self.add_image(image.id) if image
      if image_ids_to_generate.count > 2
        image_ids_to_generate.each_slice(3) do |batch|
          GenerateImagesJob.perform_async(batch, id)
        end
        image_ids_to_generate = []
      end
    end
    self.set_current_word_list
    self.save!
    if image_ids_to_generate.any?
      image_ids_to_generate.each_slice(3) do |batch|
        GenerateImagesJob.perform_async(batch, id)
      end
    end
  end

  def remove_image(image_id)
    return unless image_ids.include?(image_id.to_i)
    bi = board_images.find_by(image_id: image_id)
    bi.destroy if bi
  end

  def remove_board_image(board_image_id)
    bi = board_images.find_by(id: board_image_id)
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

    language_settings = @image.language_settings || {}
    language_settings[self.language] = { "display_label" => @image.label, "label" => @image.label }
    self.voice = VoiceService.normalize_voice(self.voice)
    new_board_image = board_images.new(image_id: image_id.to_i, voice: self.voice, position: board_images_count, language: self.language)
    new_board_image.set_labels
    new_board_image.part_of_speech = @image.part_of_speech || "default"
    new_board_image.set_colors
    if layout
      new_board_image.layout = layout
      if new_board_image.layout_invalid?
        new_board_image.set_initial_layout!
      end
      new_board_image.skip_initial_layout = true
      unless new_board_image.save
        Rails.logger.error "Failed to add image #{image_id} to board #{id} with provided layout: #{new_board_image.errors.full_messages.join(", ")}"
      end
    else
      unless new_board_image.save
        Rails.logger.error "Failed to add image #{image_id} to board #{id}: #{new_board_image.errors.full_messages.join(", ")}"
      end
      new_board_image.set_initial_layout!
    end
    unless @image
      Rails.logger.error "Image not found: #{image_id}"
      return
    end

    # Audio generation is enqueued by BoardImage's after_create callback
    # (create_voice_audio_after_create). Don't enqueue SaveAudioJob a second
    # time here.
    new_board_image.src = @image.display_image_url(self.user)

    unless new_board_image.save
      Rails.logger.error "new_board_image.errors: #{new_board_image.errors.full_messages}"
      return
    end
    self.save!

    Rails.logger.error "NO IMAGE FOUND" unless new_board_image
    new_board_image
  end

  def clone_with_images(cloned_user_id, new_name = nil, updated_voice = nil, communicator_account = nil)
    if new_name.blank?
      new_name = name
    end
    @source = self
    cloned_user = User.find(cloned_user_id)
    unless cloned_user
      cloned_user_id = User::DEFAULT_ADMIN_ID
      cloned_user = User.find(cloned_user_id)
      if !cloned_user
        Rails.logger.error "Cloned user not found: #{cloned_user_id}"
        return
      end
    end
    @images = @source.images
    @board_images = @source.board_images
    @layouts = @board_images.pluck(:image_id, :layout)

    @cloned_board = @source.dup
    # A clone gets its own freshly-generated preview (enqueued below via
    # run_generate_preview_job). `dup` copies the source's
    # display_image_url column verbatim — for boards that follow their
    # preview that string points at the *source's* image, so the clone
    # would render the wrong board. Default every clone to "follow my
    # own preview" and drop the inherited snapshot.
    @cloned_board.write_attribute(:display_image_url, nil)
    @cloned_board.settings = (@cloned_board.settings || {}).merge(
      "display_follows_preview" => true,
    )
    @cloned_board.user_id = cloned_user_id
    @cloned_board.name = new_name
    @cloned_board.predefined = false
    @cloned_board.obf_id = nil
    @cloned_board.generated_token = nil
    @cloned_board.generated_token_expires_at = nil
    @cloned_board.board_type = @source.board_type
    @cloned_board.data = {}
    @cloned_board.board_images_count = 0
    @cloned_board.generate_unique_slug
    @cloned_board.voice = updated_voice || voice
    @cloned_board.is_template = communicator_account.present?
    @cloned_board.save

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
      new_board_image.board_id = @cloned_board.id
      new_board_image.image_id = image.id
      new_board_image.set_labels
      if new_board_image
        new_board_image.display_label = board_image.display_label

        new_board_image.voice = board_image.voice
        new_board_image.predictive_board_id = board_image.predictive_board_id
        new_board_image.audio_url = board_image.audio_url
        new_board_image.save
      end
    end
    @cloned_board.run_generate_preview_job if @cloned_board.board_images.any? && @cloned_board.valid?

    unless communicator_account.nil? || communicator_account.child_boards.where(board_id: @cloned_board.id).exists?
      comm_board = communicator_account.child_boards.new(board: @cloned_board, created_by_id: cloned_user_id, original_board: @source)
      unless comm_board.save
        Rails.logger.error "Error creating ChildBoard for communicator account #{communicator_account.id} and board #{@cloned_board.id}: #{comm_board.errors.full_messages.join(", ")}"
      end
    end

    if @cloned_board.valid?
      if @source.user_id != cloned_user_id
        UpdateUserBoardsJob.perform_async(@cloned_board.id, @source.id)
      end
      @cloned_board
    else
      Rails.logger.error "Error cloning board: #{@cloned_board}"
    end
  end

  def clone_and_update_predictive_board(original_board_image, new_board_image, updated_voice, cloned_user_id)
    return unless original_board_image.predictive_board_id
    predictive_board = Board.find_by(id: original_board_image.predictive_board_id)
    return unless predictive_board
    if predictive_board.user_id == cloned_user_id
      new_board_image.predictive_board_id = predictive_board.id
      new_board_image.save
      return
    end
    if predictive_board.public_board?
      new_board_image.predictive_board_id = predictive_board.id
      new_board_image.save
      return
    end

    CloneBoardJob.perform_async(predictive_board.id, new_board_image.id)
  end

  def update_user_boards_after_cloning(source_board, cloned_user_id)
    user_boards = user.total_board_images.where(predictive_board_id: source_board.id)
    cloned_board = self
    user_boards.each do |bi|
      bi.predictive_board_id = cloned_board.id
      unless bi.save
        Rails.logger.error "Error saving board image #{bi.id} with predictive_board_id #{cloned_board.id}: #{bi.errors.full_messages.join(", ")}"
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

  def current_word_list
    return data["current_word_list"] if data && data["current_word_list"].present?
    set_current_word_list
  end

  def set_current_word_list
    data = self.data || {}

    words = board_images.order(:position).pluck(:label)
    return [] if words.blank?

    data["current_word_list"] = words
    words
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

    self.layout[screen_size] = layout_to_set
    self.board_images.reset
    self.save!
  end

  def self.create_slug(name_to_use)
    cleaned_name = name_to_use.gsub(/(copy[- ]of[\s_-]*)/i, "").squeeze(" ").strip
    cleaned_name = cleaned_name.parameterize
    cleaned_name
  end

  def generate_unique_slug(initial_slug = nil)
    name_to_use = initial_slug || name
    # Remove both "Copy of " and "copy-of-" (case-insensitive)
    cleaned_name = Board.create_slug(name_to_use)
    slug = cleaned_name
    # counter = 1

    while Board.where(slug: slug).where.not(id: id).exists?
      random_string = SecureRandom.hex(4)
      slug = "#{cleaned_name}-#{random_string}"
      # counter += 1
    end
    self.slug = slug
    slug
  end

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

  # Persist a layout change for a given screen size. Sorts the items, updates
  # each board_image's position, optionally writes screen-size column counts,
  # margin settings, and per-screen settings, then delegates to
  # update_grid_layout and queues a preview regenerate.
  def apply_layout!(layout:, screen_size: "lg", columns: {}, margins: {}, settings: nil)
    return if layout.blank?

    sorted_layout = layout.sort_by { |item| [item["y"].to_i, item["x"].to_i] }

    sorted_layout.each_with_index do |item, i|
      board_image_id = item["i"].to_i
      board_image = board_images.find_by(id: board_image_id)
      if board_image
        board_image.update!(position: i)
      else
        Rails.logger.error "Board image not found for ID: #{board_image_id}"
      end
    end

    self.small_screen_columns = columns[:small_screen_columns].to_i if columns[:small_screen_columns].present?
    self.medium_screen_columns = columns[:medium_screen_columns].to_i if columns[:medium_screen_columns].present?
    self.large_screen_columns = columns[:large_screen_columns].to_i if columns[:large_screen_columns].present?

    if margins[:x].present? && margins[:y].present?
      self.margin_settings[screen_size] = { x: margins[:x].to_i, y: margins[:y].to_i }
    end

    self.settings[screen_size] = settings if settings.present?
    save!

    begin
      update_grid_layout(sorted_layout, screen_size)
      run_generate_preview_job
    rescue => e
      Rails.logger.error "Error updating grid layout: #{e.message}\n#{e.backtrace.join("\n")}"
    end
    reload
  end

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

  # Format the board's layout using AI for word ordering + tile sizing, then
  # deterministically pack tiles in Ruby so we never persist overlapping or
  # gap-ridden layouts. Writes per-board_image layouts (primary source of
  # truth for ViewBoard / EditBoardScreen via DraggableGrid) AND the board's
  # aggregate layout (source of truth for BoardNativeGridPage) for all three
  # screen sizes in one pass.
  #
  # screen_size is accepted for back-compat with callers but no longer affects
  # behavior — all three screens are always written.
  def format_board_with_ai(screen_size: "lg", maintain_existing_layout: false)
    images = board_images.includes(:image).to_a
    return self if images.empty?

    lg_columns = get_number_of_columns("lg")
    rows_hint = (images.size / lg_columns.to_f).ceil

    existing = images.map do |bi|
      layout = (bi.layout || {}).dig("lg") || {}
      {
        word: bi.label,
        size: [layout["w"], layout["h"]].compact.presence || [1, 1],
        board_type: bi.predictive_board_id ? Board.find_by(id: bi.predictive_board_id)&.board_type : nil,
      }
    end

    payload = AiBoardFormatter.call(
      name: name,
      columns: lg_columns,
      rows: rows_hint,
      existing: existing,
      maintain_existing: maintain_existing_layout,
    )

    return self if payload.blank?

    ordered = Array(payload["ordered_words"])
    by_label = images.index_by { |bi| bi.label.to_s.downcase }

    # Build ordered (board_image, w, h, meta) tuples from the AI output.
    ordered_items = []
    seen_ids = Set.new
    ordered.each do |item|
      label = item["word"].to_s
      bi = by_label[label.downcase]
      next if bi.nil? || seen_ids.include?(bi.id)
      seen_ids << bi.id

      size = Array(item["size"])
      w = size[0].to_i
      h = size[1].to_i
      w = 1 if w < 1
      h = 1 if h < 1

      ordered_items << {
        board_image: bi,
        w: w,
        h: h,
        frequency: item["frequency"],
        part_of_speech: item["part_of_speech"],
      }
    end

    # Append any board_images the AI dropped so we never lose tiles.
    images.each do |bi|
      next if seen_ids.include?(bi.id)
      ordered_items << { board_image: bi, w: 1, h: 1, frequency: nil, part_of_speech: nil }
    end

    # Pack a layout per screen size using the same ordering.
    packed_by_screen = {}
    SCREEN_SIZES_FOR_AI_LAYOUT.each do |screen|
      columns = get_number_of_columns(screen)
      packed_by_screen[screen] = pack_layout_row_major(ordered_items, columns: columns)
    end

    ActiveRecord::Base.transaction do
      ordered_items.each_with_index do |item, idx|
        bi = item[:board_image]

        bi.data ||= {}
        bi.data["label"] = bi.label.to_s
        bi.data["part_of_speech"] = item[:part_of_speech] if item[:part_of_speech].present?
        bi.data["bg_color"] = bi.background_color_for(item[:part_of_speech]) if item[:part_of_speech].present?

        bi.layout ||= {}
        SCREEN_SIZES_FOR_AI_LAYOUT.each do |screen|
          cell = packed_by_screen[screen][idx]
          bi.data[screen] ||= {}
          bi.data[screen]["frequency"] = item[:frequency] if item[:frequency].present?
          bi.data[screen]["size"] = [cell["w"], cell["h"]]
          bi.layout[screen] = cell
        end

        bi.position = idx
        bi.skip_create_voice_audio = true if bi.respond_to?(:skip_create_voice_audio=)
        bi.save!
        bi.clean_up_layout

        if item[:part_of_speech].present? && bi.image && bi.image.part_of_speech.blank?
          bi.image.update!(part_of_speech: item[:part_of_speech])
        end
      end

      # Mirror per-image layout up to board.layout for each screen so
      # BoardNativeGridPage (which reads board.layout) stays in lockstep.
      self.layout ||= {}
      SCREEN_SIZES_FOR_AI_LAYOUT.each do |screen|
        self.layout[screen] = packed_by_screen[screen]
      end

      personable = payload["personable_explanation"].presence
      professional = payload["professional_explanation"].presence

      self.data ||= {}
      self.data["personable_explanation"] = personable if personable
      self.data["professional_explanation"] = professional if professional
      if (personable || professional) && description.blank?
        self.description = [self.data["personable_explanation"], self.data["professional_explanation"]].compact.join("\n")
      end

      save!
      board_images.reset
    end

    self
  end

  SCREEN_SIZES_FOR_AI_LAYOUT = %w[sm md lg].freeze
  private_constant :SCREEN_SIZES_FOR_AI_LAYOUT

  # Row-major packer with occupancy tracking. Walks ordered items, places
  # each tile at the first free top-left cell that fits its w×h footprint
  # without overlap. Clamps w to the column count and h to 2 (frontend assumes
  # short tiles).
  #
  # ordered_items: array of { board_image:, w:, h:, ... }
  # returns: array of { "i", "x", "y", "w", "h" } in the same order as input.
  def pack_layout_row_major(ordered_items, columns:)
    columns = columns.to_i
    columns = 1 if columns < 1
    occupied = Set.new
    out = []

    ordered_items.each do |item|
      w = item[:w].to_i.clamp(1, columns)
      h = item[:h].to_i.clamp(1, 2)

      placed = false
      y = 0
      until placed
        (0..(columns - w)).each do |x|
          cells = []
          w.times do |dx|
            h.times { |dy| cells << [x + dx, y + dy] }
          end
          if cells.none? { |c| occupied.include?(c) }
            cells.each { |c| occupied << c }
            out << { "i" => item[:board_image].id.to_s, "x" => x, "y" => y, "w" => w, "h" => h }
            placed = true
            break
          end
        end
        y += 1 unless placed
      end
    end

    out
  end
  private :pack_layout_row_major

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
      return resource_type&.downcase
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
    "#{base_url}/pb/#{slug}"
  end

  def featured
    predefined && favorite
  end

  def communicator_board
    if is_template
      @communicator_board ||= ChildBoard.includes(:child_account).find_by(board_id: id)
    end
  end

  def communicator_account
    if is_template
      communicator_board&.child_account
    end
  end

  def schedule_translations_for(language)
    language = language.to_s
    return if language.blank? || language == "en"
    return unless Image.languages.include?(language)

    cache_key = "translate_board:#{id}:#{language}"
    return if Rails.cache.exist?(cache_key)

    TranslateBoardImagesJob.perform_async(id, language)
    Rails.cache.write(cache_key, true, expires_in: 1.hour)
  end

  def api_view_for_native_grid(viewing_user = nil, show_hidden = false, voice_to_play = nil)
    viewer_lang = viewing_user.respond_to?(:i18n_locale) ? viewing_user.i18n_locale.to_s : nil
    schedule_translations_for(viewer_lang) if viewer_lang.present?
    @board_images = show_hidden ? board_images.includes(:image) : visible_board_images.includes(:image)
    {
      id: id,
      board_type: board_type,
      user_id: user_id,
      board_id: id,
      voice: voice,
      margin_settings: margin_settings,
      data: data,
      created_at: created_at,
      updated_at: updated_at,
      settings: settings,
      published: published,
      has_generating_images: has_generating_images?,
      number_of_columns: number_of_columns,
      small_screen_columns: small_screen_columns,
      medium_screen_columns: medium_screen_columns,
      large_screen_columns: large_screen_columns,
      large_screen_rows: rows_for_screen_size("lg"),
      medium_screen_rows: rows_for_screen_size("md"),
      small_screen_rows: rows_for_screen_size("sm"),
      status: status,
      slug: slug,
      name: name,
      frozen: settings && settings["freeze_board"] == true,
      images: @board_images.map do |board_image|
        @board_image = board_image

        @image = @board_image.image
        @full_src_url = @board_image.display_image_url || @image.display_image_url(viewing_user) || @image.src_url

        is_owner = viewing_user && @image.user_id == viewing_user&.id
        is_admin_image = [User::DEFAULT_ADMIN_ID, nil].include?(user_id)

        @predictive_board_id = @board_image.predictive_board_id
        @predictive_board = @board_image.predictive_board

        @viewer_settings = viewing_user&.settings || {}
        @predictive_board_settings = @predictive_board&.settings || {}

        @user_custom_default_id = @viewer_settings["opening_board_id"]

        is_dynamic = @board_image.is_dynamic?
        is_predictive = @image.predictive?
        if @board_image.predictive_board_id == @root_board&.id
          is_dynamic = false
        end

        is_category = @predictive_board && @predictive_board.board_type == "category"
        freeze_board = @predictive_board_settings["freeze_board"] == true
        is_first_image = @board_image.position == 0

        @board_image.data ||= {}
        mute_name = @board_image.data["mute_name"] == true
        using_custom_audio = @board_image.using_custom_audio?
        @board_settings = settings || {}
        freeze_parent_board = @board_settings["freeze_board"] == true
        if show_hidden
          @board_images = board_images.includes({ image: [:docs, :audio_files_attachments, :audio_files_blobs, :predictive_boards] }, :predictive_board).distinct
        else
          @board_images = visible_board_images.includes({ image: [:docs, :audio_files_attachments, :audio_files_blobs, :predictive_boards] }, :predictive_board).distinct
        end

        if voice_to_play.present? && @board_image.voice != voice_to_play && !using_custom_audio
          current_audio_url = @board_image.audio_url_for_voice(voice_to_play)
          unless current_audio_url
            SaveAudioJob.perform_async(@image.id, voice_to_play, @board_image.id)
            current_audio_url = @board_image.audio_url
          end
        else
          current_audio_url = @board_image.audio_url
        end
        {
          id: @board_image.id,
          image_id: @image.id,
          label: @board_image.localized_label(viewer_lang),
          display_label: @board_image.localized_display_label(viewer_lang),
          hidden: @board_image.hidden,
          root_board_id: @root_board&.id,
          root_board_name: @root_board&.name,
          board_id: id,
          board_name: name,
          image_user_id: @image.user_id,
          predictive_board_id: @predictive_board_id,
          user_custom_default_id: @user_custom_default_id,
          predictive_board_board_type: @predictive_board&.board_type,
          predictive_board_name: @predictive_board&.name,
          freeze_board: freeze_board,
          freeze_parent_board: freeze_parent_board,
          is_first_image: is_first_image,
          override_frozen: @board_image.override_frozen,
          position: @board_image.position,
          dynamic: is_dynamic,
          is_predictive: is_predictive,
          board_image_id: @board_image.id.to_s,
          board_frozen: freeze_parent_board,
          data: @board_image.data,
          image_prompt: @board_image.image_prompt,
          bg_color: @board_image.bg_color,
          bg_class: @board_image.bg_class,
          bg_hex: @board_image.bg_hex,
          text_color: @board_image.text_color,
          border_color: @board_image.border_color,
          border_width: @board_image.border_width,
          border_radius: @board_image.border_radius,
          next_words: @board_image.next_words,
          src_url: @full_src_url,
          mute_name: mute_name,
          hide_label: @board_image.hide_label,
          src: @full_src_url,
          full_src: @full_src_url,
          display_image_url: @full_src_url,
          tile_src: @full_src_url,
          audio_url: current_audio_url,
          voice: @board_image.voice,
          layout: @board_image.layout.with_indifferent_access,
          added_at: @board_image.added_at,
          part_of_speech: @image.part_of_speech,
          status: @board_image.status,
        }
      end,
    # layout: print_grid_layout,
    }
  end

  def api_view_with_predictive_images(viewing_user = nil, show_hidden = false, voice_to_play = nil)
    viewer_lang = viewing_user.respond_to?(:i18n_locale) ? viewing_user.i18n_locale.to_s : nil
    schedule_translations_for(viewer_lang) if viewer_lang.present?
    @viewer_settings = viewing_user&.settings || {}
    is_a_user = viewing_user.class == "User"
    is_a_communicator = viewing_user.class == "ChildAccount"
    current_account = nil
    if is_a_user
      current_account = viewing_user
    elsif is_a_communicator
      current_account = viewing_user
    end
    @board_settings = settings || {}
    freeze_parent_board = @board_settings["freeze_board"] == true
    if show_hidden
      @board_images = board_images.includes({ image: [:docs, :audio_files_attachments, :audio_files_blobs, :predictive_boards] }, :predictive_board).distinct
    else
      @board_images = visible_board_images.includes({ image: [:docs, :audio_files_attachments, :audio_files_blobs, :predictive_boards] }, :predictive_board).distinct
    end
    current_colors = @board_images.map { |bi| bi.bg_color }.flatten.compact.uniq
    if in_use
      @original_child_boards = original_child_boards.includes(child_account: :profile)
    end
    @parent_boards = parent_boards(viewing_user&.id)
    @child_accounts = @original_child_boards&.map(&:child_account).compact.uniq if @original_child_boards

    @root_board = root_board
    same_user = viewing_user && user_id == viewing_user.id
    can_edit = same_user || viewing_user&.admin?
    if current_account
      #  For future implementation - can add more granular permissions for communicators
      can_edit = current_account.settings["can_edit_boards"] == true
    end
    # Plan gating: a free user over their board limit can edit only their one
    # designated board (User#board_editable?). Non-User viewers untouched.
    can_edit &&= viewing_user.board_editable?(self) if can_edit && viewing_user.is_a?(User)
    {
      id: id,
      board_type: board_type,
      board_id: id,
      word_sample: word_sample,
      user_name: user&.display_name,
      communicator_account_data: @original_child_boards&.map { |cb| { acct_id: cb.child_account.id, board_id: cb.board_id, original_board_id: cb.original_board_id, acct_name: cb.child_account.name, board_name: cb.board.name, acct_avatar_url: cb.child_account.profile&.avatar_url } },
      communicator_accounts: @child_accounts&.map { |ca| { id: ca.id, name: ca.name } },
      communicator_account: communicator_account ? { id: communicator_account.id, name: communicator_account.name } : nil,
      communicator_board: communicator_board ? { id: communicator_board.id, name: communicator_board.name, board_id: communicator_board.board_id, original_board_id: communicator_board.original_board_id } : nil,
      child_boards: @original_child_boards&.map { |cb| { board_id: cb.board_id, name: cb.name, child_account_id: cb.child_account_id, username: cb.child_account&.username } },
      in_use: in_use,
      is_template: is_template,
      parent_boards: @parent_boards&.map { |pb| { id: pb.id, name: pb.name, slug: pb.slug, board_type: pb.board_type, display_image_url: pb.display_image_url || pb.preview_image_url, preview_image_url: pb.preview_image_url } },
      public_url: public_url,
      # board_groups: board_groups,
      slug: slug,
      bg_color: bg_color,
      text_color: text_color,
      source_type: source_type,
      vendor: vendor,
      week_chart: week_chart,
      menu_id: board_type === "menu" ? parent_id : nil,
      name: name,
      root_board: @root_board,
      language: language,
      preview_image_url: preview_image_url,
      pdf_url: pdf_url,
      download_pdf_url: download_pdf_url,
      generated_token: generated_token,
      generated_token_expires_at: generated_token_expires_at,
      tags: tags,
      word_list: current_word_list,
      description: description,
      featured: featured,
      can_edit: can_edit,
      locked: locked_for?(viewing_user),
      lock_reason: locked_for?(viewing_user) ? "free_plan_board_limit" : nil,
      category: category,
      parent_type: parent_type,
      parent_id: parent_id,
      vendor_id: vendor_id,
      obf_id: obf_id,
      image_count: board_images_count,
      frozen: is_frozen?,
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
      display_image_url: display_image_url || preview_image_url,
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
      current_colors: current_colors,
      images: @board_images.map do |board_image|
        @board_image = board_image
        @image = @board_image.image
        @full_src_url = @board_image.display_image_url || @image.display_image_url(viewing_user) || @image.src_url

        is_owner = viewing_user && @image.user_id == viewing_user&.id
        is_admin_image = [User::DEFAULT_ADMIN_ID, nil].include?(user_id)

        @predictive_board_id = @board_image.predictive_board_id
        @predictive_board = @board_image.predictive_board

        @viewer_settings = viewing_user&.settings || {}
        @predictive_board_settings = @predictive_board&.settings || {}

        @user_custom_default_id = @viewer_settings["opening_board_id"]

        is_dynamic = @board_image.is_dynamic?
        is_predictive = @image.predictive?
        if @board_image.predictive_board_id == @root_board&.id
          is_dynamic = false
        end

        is_category = @predictive_board && @predictive_board.board_type == "category"
        freeze_board = @predictive_board_settings["freeze_board"] == true
        is_first_image = @board_image.position == 0

        @board_image.data ||= {}
        mute_name = @board_image.data["mute_name"] == true
        using_custom_audio = @board_image.using_custom_audio?

        if voice_to_play.present? && @board_image.voice != voice_to_play && !using_custom_audio
          current_audio_url = @board_image.audio_url_for_voice(voice_to_play)
          unless current_audio_url
            SaveAudioJob.perform_async(@image.id, voice_to_play, @board_image.id)
            current_audio_url = @board_image.audio_url
          end
        else
          current_audio_url = @board_image.audio_url
        end
        {
          id: @board_image.id,
          image_id: @image.id,
          label: @board_image.localized_label(viewer_lang),
          display_label: @board_image.localized_display_label(viewer_lang),
          hidden: @board_image.hidden,
          root_board_id: @root_board&.id,
          root_board_name: @root_board&.name,
          board_id: id,
          board_name: name,
          image_user_id: @image.user_id,
          using_custom_audio: using_custom_audio,
          # docs: @image.docs.for_user(viewing_user).order(created_at: :desc).limit(15).map { |doc| doc.api_view(viewing_user) },
          predictive_board_id: @predictive_board_id,
          user_custom_default_id: @user_custom_default_id,
          predictive_board_board_type: @predictive_board&.board_type,
          predictive_board_name: @predictive_board&.name,
          is_owner: is_owner,
          is_category: is_category,
          is_admin_image: is_admin_image,
          freeze_board: freeze_board,
          freeze_parent_board: freeze_parent_board,

          is_first_image: is_first_image,
          image_language_settings: @image.language_settings,
          override_frozen: @board_image.override_frozen,
          position: @board_image.position,
          dynamic: is_dynamic,
          is_predictive: is_predictive,
          board_image_id: @board_image.id.to_s,
          board_frozen: freeze_parent_board,
          data: @board_image.data,
          image_prompt: @board_image.image_prompt,
          bg_color: @board_image.bg_color,
          border_width: @board_image.border_width,
          border_radius: @board_image.border_radius,
          border_color: @board_image.border_color,
          bg_class: @board_image.bg_class,
          bg_hex: @board_image.bg_hex,
          hide_label: @board_image.hide_label,
          text_color: @board_image.text_color,
          next_words: @board_image.next_words,
          src_url: @full_src_url,
          mute_name: mute_name,
          src: @full_src_url,
          full_src: @full_src_url,
          display_image_url: @full_src_url,
          tile_src: @full_src_url,
          audio_url: current_audio_url,
          voice: @board_image.voice,
          layout: @board_image.layout.with_indifferent_access,
          added_at: @board_image.added_at,
          part_of_speech: @image.part_of_speech,
          status: @board_image.status,
        }
      end,
    # layout: print_grid_layout,
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
    layout = print_grid_layout_for_screen_size(screen_size)
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

  def columns_for_screen_size(screen_size = "lg")
    case screen_size
    when "sm"
      small_screen_columns > 0 ? small_screen_columns : 4
    when "md"
      medium_screen_columns > 0 ? medium_screen_columns : 6
    when "lg"
      large_screen_columns > 0 ? large_screen_columns : 12
    else
      large_screen_columns > 0 ? large_screen_columns : 12
    end
  end

  def list_api_view(viewing_user = nil)
    {
      id: id,
      board_id: id,
      bg_color: bg_color,
      text_color: text_color,
      slug: slug,
      name: name,
      word_list: current_word_list,
      can_edit: can_edit_for(viewing_user),
      locked: locked_for?(viewing_user),
      lock_reason: locked_for?(viewing_user) ? "free_plan_board_limit" : nil,
      is_template: is_template,
      display_image_url: display_image_url,
      preview_image_url: preview_image_url,
      user_id: user_id,
    }
  end

  def in_use_by
    if in_use
      @original_child_boards = original_child_boards.includes(child_account: :profile)
      @communicator_accounts = @original_child_boards&.map(&:child_account).compact.uniq
      @communicator_accounts&.map(&:name)&.join(", ")
    end
  end

  # Whether viewing_user may edit this board's content. Owner/admin gate plus
  # the plan-based read-only rule (User#board_editable?). Non-User viewers
  # (e.g. ChildAccount) are not plan-gated here.
  def can_edit_for(viewing_user)
    return false unless viewing_user
    return false unless user_id == viewing_user.id || viewing_user.try(:admin?)
    return true unless viewing_user.is_a?(User)

    viewing_user.board_editable?(self)
  end

  # True ONLY when this board is read-only for viewing_user because of the
  # plan-based gate (User#board_editable?). False for non-owners, admins,
  # paid users, ChildAccount viewers (their can_edit comes from a different
  # permission, not a lock), and any case where the user could edit.
  # This is what the frontend uses to show the "Read-only — make this my
  # editable board" banner.
  def locked_for?(viewing_user)
    return false unless viewing_user.is_a?(User)
    return false unless user_id == viewing_user.id
    return false if viewing_user.admin?

    !viewing_user.board_editable?(self)
  end

  def api_view(viewing_user = nil)
    can_edit = can_edit_for(viewing_user)
    locked = locked_for?(viewing_user)

    @in_a_public_group = false
    @display_image_url = display_image_url
    @preview_image_url = preview_image_url

    if viewing_user && viewing_user.admin?
      @in_a_public_group = in_a_public_group?
    end
    {
      id: id,
      board_id: id,
      slug: slug,
      bg_color: bg_color,
      text_color: text_color,
      tags: tags,
      user_name: user.to_s,
      name: name,
      is_template: is_template,
      public_board: public_board?,
      in_a_public_group: @in_a_public_group,
      published: published,
      in_use: in_use,
      in_use_by: in_use_by,
      communicator_account_data: in_use ? @original_child_boards&.map { |cb| { acct_id: cb.child_account.id, board_id: cb.board_id, original_board_id: cb.original_board_id, acct_name: cb.child_account.name, board_name: cb.board.name, acct_avatar_url: cb.child_account.profile&.avatar_url } } : nil,
      can_edit: can_edit,
      locked: locked,
      lock_reason: locked ? "free_plan_board_limit" : nil,
      layout: layout,
      audio_url: audio_url,
      group_layout: group_layout,
      position: position,
      word_sample: word_sample,
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
      display_image_url: @display_image_url || @preview_image_url,
      preview_image_url: @preview_image_url,
      board_type: board_type,
      user_id: user_id,
      voice: voice,
      word_list: data ? data["current_word_list"] : nil,
      settings: settings,
      margin_settings: margin_settings,
      preset_display_image_url: preset_display_image_url,
      board_images_count: board_images_count,
      obf_id: obf_id,
      board_screenshot_import_id: board_screenshot_import_id,
      created_at: created_at,
      updated_at: updated_at,
      is_owner: user_id == viewing_user&.id,
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
      bg_color: bg_color,
      text_color: text_color,
      # image_count: board_images_count,
      can_edit: can_edit_for(viewing_user),
      locked: locked_for?(viewing_user),
      lock_reason: locked_for?(viewing_user) ? "free_plan_board_limit" : nil,
      display_image_url: display_image_url,
      preview_image_url: preview_image_url,
      word_sample: word_sample,
      frozen: is_frozen?,
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
      if user
        self.parent_id = user.id
      else
        Rails.logger.error "No user found for board #{id} when assigning parent"
        self.parent_id = User::DEFAULT_ADMIN_ID
        self.board_type = "generated"
      end
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

  def get_words(name_to_send, number_of_words, words_to_exclude = [], use_preview_model = false, language: nil, profile: nil)
    lang = language.presence || self.language.presence || "en"
    words_to_exclude = board_images.pluck(:label).map { |w| w.downcase }
    response = OpenAiClient.new({}).get_additional_words(self, name_to_send, number_of_words, words_to_exclude, use_preview_model, lang, profile: profile)
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

  def get_words_for_predictive(starting_phrase_or_word, word_count, language: nil, profile: nil)
    word_or_phrase = starting_phrase_or_word.split(" ").size > 1 ? "phrase" : "word"
    text = "Generate a list of #{word_count} words that would commonly follow the #{word_or_phrase} '#{starting_phrase_or_word}' in everyday communication. These words will be used on a predictive communication board to help users quickly find and select common phrases. Please provide words that are relevant and commonly used in conjunction with '#{starting_phrase_or_word}'."
    words = get_word_suggestions_from_prompt(text, language: language, profile: profile)
    words
  end

  def get_words_for_scenario(topic, age_range, word_count, language: nil, profile: nil)
    words_to_exclude = data["current_word_list"] || []
    # ensure word count is reasonable to avoid excessively long prompts & not 0
    if word_count <= 0 || word_count > 80
      Rails.logger.warn "Word count of #{word_count} is out of bounds for Board ID #{id}. Defaulting to 24."
      word_count = 24
    end
    # Fall back to the legacy free-text age_range when no structured profile was passed.
    profile ||= CommunicatorProfile.from_params(age_range: age_range)
    text = "Generate a list of words for a communication board. The topic or theme of the board is #{topic}. The name of the board is #{name}. "
    text += "The age range for the person using the board is #{age_range}. Please provide a list of #{word_count} words that are appropriate for this age range and context. " if age_range.present?
    text += "Please provide a list of #{word_count} words that are appropriate for this context. " if age_range.blank?
    text += "Exclude words that are too similar to each other or that would not be useful on a communication board. Also exclude words that are already on the board: #{words_to_exclude.join(", ")}." if words_to_exclude.any?
    words = get_word_suggestions_from_prompt(text, language: language, profile: profile)
    words
  end

  def get_word_suggestions(name_to_use, number_of_words, words_to_exclude = [], language: nil, profile: nil)
    lang = language.presence || self.language.presence || "en"
    response = OpenAiClient.new({}).get_word_suggestions(name_to_use, number_of_words, words_to_exclude, board_type, language: lang, profile: profile)
    begin
      if response && response[:content].present?
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

  def get_social_story_word_suggestions(name_to_use, number_of_steps, max_number_of_words, words_to_exclude = [], language: nil)
    lang = language.presence || self.language.presence || "en"
    response = OpenAiClient.new({}).get_social_story_word_suggestions(name_to_use, number_of_steps, max_number_of_words, words_to_exclude, language: lang)
    begin
      if response && response[:content].present?
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
        Rails.logger.error "*** ERROR - get_social_story_word_suggestions *** \nDid not receive valid response. Response: #{response}\n"
      end
      word_suggestions["words"]
    rescue => e
      Rails.logger.error "Error getting social story word suggestions: #{e}"
    end
  end

  def get_word_suggestions_from_default_prompt(prompt, number_of_words, language: nil, profile: nil)
    words_to_exclude = current_word_list || []
    text = "Generate a list of EXACTLY #{number_of_words} words or short phrases based on the following prompt: #{prompt}. "
    unless words_to_exclude.blank?
      text += "The current words on the board are: #{words_to_exclude.join(", ")}. Please exclude these from your suggestions but you can use them as context to create a cohesive AAC board. "
    end
    if board_type == "menu"
      text += "The board is a restaurant menu, so please include words/phrases that would commonly be found on a restaurant menu such as food items, drinks, common modifiers (like \"with cheese\" or \"no onions\"), and other relevant words/phrases that would help someone communicate their order effectively in a restaurant setting. Infer the type of restaurant from the prompt and suggest words/phrases accordingly. "
    else
      text += "The words/phrases will be used on an AAC board, so please prioritize common, relevant, and useful words/phrases that would help someone communicate effectively. "
    end
    text += "Please make them lowercase with the exception of proper nouns, senetences, etc. that should be capitalized. "
    get_word_suggestions_from_prompt(text, language: language, profile: profile)
  end

  def get_word_suggestions_from_prompt(prompt, language: nil, profile: nil)
    lang = language.presence || self.language.presence || "en"
    response = OpenAiClient.new({}).get_word_suggestions_from_prompt(prompt, language: lang, profile: profile)
    begin
      if response && response[:content].present?
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

  def self.normalize_voices
    self.all.each do |board|
      if board.voice.blank?
        board.update(voice: "polly:kevin")
      else
        original_voice = board.voice
        new_voice = VoiceService.normalize_voice(original_voice)
        if new_voice != original_voice
          board.update(voice: new_voice)
          Rails.logger.info "Normalized voice for board #{board.id} from '#{original_voice}' to '#{new_voice}'"
        end
      end
    end
  end

  # import_options controls copyright-sensitive behavior during OBF/OBZ import.
  # Keys (all optional, all default to safe values):
  #   include_images:           Boolean. When false (default), imported Image
  #                             records are created (always is_private: true),
  #                             but NO image binaries are downloaded or attached
  #                             to Docs. When true, attach_image_doc runs.
  #   license_acknowledged:     Boolean. Audit-only; recorded by ObzImporter on
  #                             BoardGroup.settings. Must be true to set
  #                             include_images: true (enforced by controller).
  #   acknowledged_by_user_id:  Integer. Audit-only.
  #   apply_button_attributes:  Boolean. When true, each button's authored
  #                             part_of_speech (and OBF-standard
  #                             background_color / border_color when present) is
  #                             applied to the BoardImage, so tile colors follow
  #                             the authored Fitzgerald key instead of whatever
  #                             the shared Image record happens to carry (#279).
  #                             Used by the VocabSets seeder; user OBZ imports
  #                             keep the historical default (off).
  def self.from_obf(data, current_user, board_group = nil, board_id = nil, import_options: {})
    obj = parse_obf_input(data)
    raise ArgumentError, "OBF data must be a Hash" unless obj.is_a?(Hash)
    import_options = (import_options || {}).symbolize_keys

    obf_id = obj["id"].to_s
    is_root = board_group && board_group.original_obf_root_id == obf_id
    grid = obj["grid"] || {}
    columns = grid["columns"]
    buttons = Array(obj["buttons"])
    images_by_obf_id = Array(obj["images"]).index_by { |img| img["id"].to_s }
    coords_by_button_id = build_coords_index(grid["order"])
    dynamic_images = buttons.select { |item| item["load_board"] }
    board_type = determine_board_type(dynamic_images, is_root)
    board_data = { obf_grid: grid }
    voice = obj["voice"] || "polly:kevin"

    board = find_or_init_board_for_import(
      board_id: board_id, obf_id: obf_id, name: obj["name"],
      user: current_user, columns: columns, voice: voice,
      board_data: board_data, board_type: board_type
    )
    board.save!

    board_group.add_board(board) if board_group
    if is_root && board_group && board_group.root_board_id != board.id
      board_group.update(root_board_id: board.id)
    end

    dynamic_data = {}
    temp_display_image = nil
    reset_layouts_after_import = obj["reset_layouts_after_import"] || false
    apply_button_attributes = import_options[:apply_button_attributes] ? true : false

    buttons.each do |item|
      image = find_or_create_image_for_button(item, current_user)
      next unless image

      doc_data = images_by_obf_id[item["image_id"].to_s]
      temp_display_image = attach_image_doc(image, doc_data, current_user, import_options: import_options) || temp_display_image

      coords = coords_by_button_id[item["id"].to_s]
      reset_layouts_after_import ||= coords.nil?

      board_image = upsert_board_image(board, image, item, coords, temp_display_image,
                                       apply_button_attributes: apply_button_attributes)
      dynamic_data[image.id] = {
        "board_id" => board.id,
        "board" => board,
        "original_obf_id" => obf_id,
        "dynamic_board" => item["load_board"],
        "label" => item["label"],
        "orginal_image_id" => item["image_id"],
        "board_image_id" => board_image.id,
      }
    end

    board.update!(display_image_url: temp_display_image) if temp_display_image
    board.reset_layouts if reset_layouts_after_import

    [board, dynamic_data]
  rescue StandardError => e
    Rails.logger.error "[Board.from_obf] #{e.class}: #{e.message}"
    Rails.logger.error e.backtrace.first(20).join("\n")
    raise
  end

  def self.parse_obf_input(data)
    case data
    when Hash then data
    when Pathname then JSON.parse(data.read)
    when String then JSON.parse(data)
    else JSON.parse(data.to_json)
    end
  end
  private_class_method :parse_obf_input

  def self.build_coords_index(grid_order)
    return {} unless grid_order.is_a?(Array)
    index = {}
    grid_order.each_with_index do |row, y|
      Array(row).each_with_index do |cell, x|
        next if cell.blank?
        index[cell.to_s] = [x, y]
      end
    end
    index
  end
  private_class_method :build_coords_index

  def self.find_or_init_board_for_import(board_id:, obf_id:, name:, user:, columns:, voice:, board_data:, board_type:)
    board = Board.find_by(id: board_id, user_id: user.id) if board_id
    board ||= Board.where.not(obf_id: nil).find_by(user_id: user.id, obf_id: obf_id)

    if board
      board.assign_attributes(
        name: name,
        large_screen_columns: columns, medium_screen_columns: columns, small_screen_columns: columns,
        number_of_columns: columns, data: board_data, voice: voice,
        obf_id: obf_id, board_type: board_type,
      )
    else
      board = Board.new(
        name: name, user_id: user.id, voice: voice,
        large_screen_columns: columns, medium_screen_columns: columns, small_screen_columns: columns,
        data: board_data, number_of_columns: columns, obf_id: obf_id, board_type: board_type,
      )
      board.generate_unique_slug
    end
    board.assign_parent
    board.generate_unique_slug if board.slug.blank?
    board
  end
  private_class_method :find_or_init_board_for_import

  # Newly-created Images from OBF/OBZ import are ALWAYS is_private: true.
  # An admin can flip the flag later via the admin UI. Existing matches are
  # returned as-is — we don't downgrade visibility on something the user
  # already owns.
  def self.find_or_create_image_for_button(item, user)
    label = item["label"]
    image = nil
    if item["ext_saw_image_id"]
      image = Image.find_by(id: item["ext_saw_image_id"].to_i, user_id: user.id)
    end
    image ||= Image.where(user_id: user.id, label: label, obf_id: item["image_id"]).order(:id).first
    image ||= Image.where(user_id: user.id, label: label).order(:id).first
    image ||= Image.create!(label: label, user_id: user.id, obf_id: item["image_id"], is_private: true)
    image
  end
  private_class_method :find_or_create_image_for_button

  # Downloads / attaches an image binary from an OBF image entry to a Doc on
  # the SpeakAnyWay Image. Copyright-sensitive: gated behind
  # import_options[:include_images]. When the user hasn't opted in, returns
  # nil and the tile renders with a label-only Image (no symbol binary).
  def self.attach_image_doc(image, doc_meta, current_user, import_options: {})
    return nil unless doc_meta
    return nil unless (import_options || {}).symbolize_keys[:include_images]

    url = doc_meta["url"]
    inline = doc_meta["data"]
    content_type = doc_meta["content_type"] || "image/png"
    content_type = "image/svg+xml" if content_type == "image/svg"
    license = doc_meta["license"]
    raw_txt = "obf_id_#{doc_meta["id"]}"
    processed = "processed: #{Time.now}"

    if url
      return url if image.docs.where(original_image_url: url).exists?
      downloaded = Down.download(url) rescue nil
      return nil unless downloaded
      doc = image.docs.create!(raw: raw_txt, user_id: current_user.id, processed: processed,
                               source_type: "ObfImport", original_image_url: url, license: license)
      doc.image.attach(io: downloaded,
                       filename: "img_#{image.label_for_filename}_#{image.id}_doc_#{doc.id}.#{doc.extension}",
                       content_type: content_type)
      image.update(status: "finished")
      PreprocessDocTileVariantJob.perform_async(doc.id) if doc.image.attached?
      url
    elsif inline
      doc = image.docs.create!(raw: raw_txt, user_id: current_user.id, processed: processed,
                               source_type: "ObfImport", original_image_url: nil, license: license)
      doc.image.attach(data: inline,
                       filename: "img_#{image.label_for_filename}_#{image.id}_doc_#{doc.id}.#{doc.extension}",
                       content_type: content_type)
      PreprocessDocTileVariantJob.perform_async(doc.id) if doc.image.attached?
      image.update(status: "finished")
      doc.reload.tile_url
    end
  end
  private_class_method :attach_image_doc

  def self.upsert_board_image(board, image, item, coords, display_url, apply_button_attributes: false)
    board_image = board.board_images.find_by(image_id: image.id)
    unless board_image
      board_image = board.board_images.new(image_id: image.id, voice: board.voice,
                                           position: board.board_images_count,
                                           display_image_url: display_url)
      # Let BoardImage's after_create :create_voice_audio_after_create
      # fire — that's the canonical hook for enqueuing SaveAudioJob, and
      # an existing pre-rendered Polly file (same image+voice+language)
      # is reused, so the job is cheap when there is one to reuse.
      # Previously skipped here; result was imported tiles had no audio
      # at all because nothing else compensated.
      board_image.save!
    end

    apply_obf_part_of_speech(board_image, image, item) if apply_button_attributes

    if coords
      layout = { "x" => coords[0], "y" => coords[1], "w" => 1, "h" => 1, "i" => board_image.id.to_s }
      board_image.layout["lg"] = layout
      board_image.layout["md"] = layout
      board_image.layout["sm"] = layout
      board_image.data ||= {}
      board_image.data["obf_id"] = item["image_id"]
      # Skip on update — after_create doesn't fire on save here anyway,
      # this just keeps the flag explicit so future readers don't think
      # we want re-enqueue on every layout tweak.
      board_image.skip_create_voice_audio = true
      board_image.save!
    elsif board_image.changed?
      board_image.skip_create_voice_audio = true
      board_image.save!
    end

    apply_obf_explicit_colors(board_image, item) if apply_button_attributes

    board_image
  end
  private_class_method :upsert_board_image

  # #279: honor the OBF button's authored part_of_speech so the tile gets its
  # Fitzgerald-key color (ColorHelper::PRESET_DATA) instead of inheriting
  # whatever the shared Image record carries. Assigns only — the caller's save
  # persists it (and BoardImage's before_update :set_colors recomputes when the
  # value changed). set_colors is also run here directly so a re-seed heals a
  # stale bg_color even when part_of_speech itself didn't change.
  # The shared Image is backfilled ONLY when its part_of_speech is blank —
  # never overwrite a value an admin (or the categorizer) already set.
  def self.apply_obf_part_of_speech(board_image, image, item)
    pos = item["part_of_speech"].presence
    return unless pos

    board_image.part_of_speech = pos
    board_image.set_colors
    # update_column: skip Image's ensure_defaults/save callbacks, which would
    # re-categorize and could fight the authored value.
    image.update_column(:part_of_speech, pos) if image.part_of_speech.blank?
  end
  private_class_method :apply_obf_part_of_speech

  # OBF-standard explicit button colors (background_color / border_color) win
  # over the part-of-speech preset. Applied via update_columns AFTER the main
  # save so BoardImage's set_colors callback can't recompute over them.
  def self.apply_obf_explicit_colors(board_image, item)
    updates = {}
    if item["background_color"].present?
      bg = ColorHelper.to_hex(item["background_color"], default: "#FFFFFF")
      updates[:bg_color] = bg
      updates[:text_color] = ColorHelper.text_hex_for(bg)
    end
    updates[:border_color] = item["border_color"] if item["border_color"].present?
    board_image.update_columns(updates) if updates.any?
  end
  private_class_method :apply_obf_explicit_colors

  def source_type
    data = self.data || {}
    data["source_type"] || nil
  end

end
