# == Schema Information
#
# Table name: board_images
#
#  id                  :bigint           not null, primary key
#  board_id            :bigint           not null
#  image_id            :bigint           not null
#  position            :integer
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  voice               :string
#  next_words          :string           default([]), is an Array
#  bg_color            :string
#  text_color          :string
#  font_size           :integer
#  border_color        :string
#  layout              :jsonb
#  status              :string           default("pending")
#  audio_url           :string
#  data                :jsonb
#  label               :string
#  display_image_url   :string
#  predictive_board_id :integer
#
class BoardImage < ApplicationRecord
  default_scope { order(position: :asc) }
  belongs_to :board, touch: true
  belongs_to :image
  belongs_to :predictive_board, class_name: "Board", optional: true
  attr_accessor :skip_create_voice_audio, :skip_initial_layout, :src

  before_create :set_defaults
  # after_create :set_next_words
  before_save :set_label, if: -> { label.blank? }
  # before_save :save_display_image_url, if: -> { display_image_url.blank? }
  before_save :check_predictive_board

  include BoardsHelper

  scope :updated_today, -> { where("updated_at > ?", 1.hour.ago) }
  scope :with_artifacts, -> { includes({ predictive_board: [{ board_images: :image }] }, :image) }

  delegate :user_id, to: :board, allow_nil: false

  def set_initial_layout!
    self.layout = { "lg" => { "i" => id.to_s, "x" => grid_x("lg"), "y" => grid_y("lg"), "w" => 1, "h" => 1 },
                    "md" => { "i" => id.to_s, "x" => grid_x("md"), "y" => grid_y("md"), "w" => 1, "h" => 1 },
                    "sm" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
                    "xs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
                    "xxs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 } }
    self.save
  end

  def set_label
    self.label = image.label
  end

  def is_dynamic?
    predictive_board_id.present? && predictive_board_id != board_id
  end

  def set_voice
    create_voice_audio(voice)
  end

  def check_predictive_board
    return unless predictive_board_id
    predictive_board = Board.find_by(id: predictive_board_id)
    unless predictive_board
      self.predictive_board_id = nil
    end
  end

  def category_boards(viewing_user_id = nil)
    viewing_user ||= board.user
    user_category_boards = Board.where(image_parent_id: image_id, user_id: viewing_user_id)
    if user_category_boards.present?
      return user_category_boards
    else
      return Board.where(image_parent_id: image_id, user_id: User::DEFAULT_ADMIN_ID, predefined: true)
    end
  end

  def layout_invalid?
    return true if layout.blank?
    return true if layout["lg"] == nil || layout["md"] == nil || layout["sm"] == nil
    return true if layout["lg"].values.any?(&:nil?) || layout["md"].values.any?(&:nil?) || layout["sm"].values.any?(&:nil?)
    return true if layout["lg"]["i"] != id.to_s || layout["md"]["i"] != id.to_s || layout["sm"]["i"] != id.to_s
    return true if layout["lg"]["w"] != 1 || layout["md"]["w"] != 1 || layout["sm"]["w"] != 1
    return true if layout["lg"]["h"] != 1 || layout["md"]["h"] != 1 || layout["sm"]["h"] != 1
    return false
  end

  def save_display_image_url
    self.display_image_url = image.src_url
  end

  def self.with_invalid_layouts
    self.includes(:board).all.select { |bi| bi.layout_invalid? }
  end

  def self.with_non_cdn_audio
    self.includes(:image).all.select { |bi| bi.audio_url && !bi.audio_url.include?("cloudfront") }
  end

  def self.fix_non_cdn_audio
    self.with_non_cdn_audio.each do |bi|
      img = bi.image
      voice = bi.voice
      audio_file = img.find_audio_for_voice(voice)

      bi.audio_url = img.default_audio_url(audio_file)
      bi.save
    end
  end

  def self.fix_invalid_layouts
    self.with_invalid_layouts.each do |bi|
      bi.set_initial_layout!
    end
  end

  def self.fix_all
    self.fix_invalid_layouts
    self.fix_non_cdn_audio
  end

  def initialize(*args)
    super
    @skip_create_voice_audio = false
  end

  def set_next_words
    return if next_words.present? || Rails.env.test?
    self.next_words = image.next_words
    save
  end

  def get_predictive_image_for(viewing_user)
    user_id_to_search = viewing_user ? viewing_user.id : nil
    images = Image.with_artifacts.where(user_id: [user_id_to_search, User::DEFAULT_ADMIN_ID], label: label)
    image = images.first
    # image = Image.where(user_id: viewing_user.id, label: label).first
    if image
      return image
    else
      return self.image
    end
  end

  def image_prompt
    image.image_prompt
  end

  def clean_up_layout
    new_layout = layout.select { |key, _| ["lg", "md", "sm", "xs", "xxs"].include?(key) }
    update!(layout: new_layout)
  end

  def bg_class
    return "bg-white" if bg_color.blank? || bg_color == "white"
    bg_color = self.bg_color || "gray"
    color = bg_color.include?("bg-") ? bg_color : "bg-#{bg_color}-400"
    color || "bg-#{image.bg_class}-400" || "bg-white"
  end

  scope :created_today, -> { where("created_at >= ?", Time.zone.now.beginning_of_day) }

  def voice_changed_and_not_existing?
    !image.existing_voices.include?(voice)
  end

  def board_images
    board.board_images.sort_by(&:position)
  end

  def grid_x(screen_size = "lg")
    return layout[screen_size]["x"] if layout[screen_size] && layout[screen_size]["x"]
    board.next_available_cell(screen_size)&.fetch("x", 0) || 0
  end

  def grid_y(screen_size = "lg")
    return layout[screen_size]["y"] if layout[screen_size] && layout[screen_size]["y"]
    board.next_available_cell(screen_size)&.fetch("y", 0) || 0
  end

  def initial_layout
    { "lg" => { "i" => id.to_s, "x" => grid_x("lg"), "y" => grid_y("lg"), "w" => 1, "h" => 1 },
      "md" => { "i" => id.to_s, "x" => grid_x("md"), "y" => grid_y("md"), "w" => 1, "h" => 1 },
      "sm" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
      "xs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
      "xxs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 } }
  end

  def calucate_position(x, y)
    x + (y * board.number_of_columns) + 1
  end

  def to_obf_image_format(viewing_user = nil)
    viewing_user ||= user
    is_dynamic = board.board_type == "dynamic"
    puts "is_dynamic: #{is_dynamic}"
    {
      id: id.to_s,
      url: display_image_url || image.display_image_url(viewing_user) || image.src_url,
      width: 850, # this might need to be changed
      height: 850, # this might need to be changed
      content_type: image.content_type,
      ext_saw_label: label,
      ext_saw_voice: voice,
      ext_board_type: board.board_type,
    }
  end

  def to_obf_sound_format
    audio_file = image.find_audio_for_voice(voice)
    {
      id: audio_file&.id.to_s,
      ext_saw_label: label,
      url: audio_url,
      ext_saw_voice: voice,
      ext_board_type: board.board_type,
      ext_saw_image_id: id.to_s,
      duration: 1, # this might need to be changed
      content_type: "audio/aac",
    }
  end

  def to_obf_button_format
    {
      id: id.to_i,
      label: label,
      image_id: id.to_s,
      background_color: get_background_color_css,
      border_color: border_color || "rgb(68, 68, 68)",
      ext_saw_image_id: image_id.to_s,
      ext_saw_board_id: board_id.to_s,
    }
  end

  def audio_file
    image.find_audio_for_voice(voice)
  end

  def create_voice_audio(voice = nil)
    voice ||= self.voice
    return if @skip_create_voice_audio || Rails.env.test?
    label_voice = "#{image.label_for_filename}_#{voice}"
    filename = "#{label_voice}.aac"
    already_has_audio_file = image.existing_audio_files.include?(filename)
    self.voice = voice
    audio_file = image.find_audio_for_voice(voice)

    if already_has_audio_file && audio_file
      self.audio_url = image.default_audio_url(audio_file)
    else
      image.find_or_create_audio_file_for_voice(voice)
      audio_file = image.find_audio_for_voice(voice)
      self.audio_url = image.default_audio_url(audio_file)
    end
    @skip_create_voice_audio = true
    save
    # board.update!(updated_at: Time.zone.now)
  end

  def user
    board.user
  end

  def predictive_board_data
    return nil unless predictive_board_id
    {
      id: predictive_board_id,
      name: predictive_board&.name,
      board_type: predictive_board&.board_type,
      display_image_url: predictive_board&.display_image_url,
    }
  end

  def api_view(viewing_user = nil)
    viewing_user ||= user
    all_img_board_images = board.board_images.includes(:image).distinct
    {
      id: id,
      image_id: image_id,
      label: label,
      board_name: board.name,
      board_type: board.board_type,
      predictive_board: predictive_board_data,
      dynamic: is_dynamic?,
      voice: voice,
      src: display_image_url,
      display_image_url: display_image_url,
      board_id: board_id,
      position: position,
      bg_color: bg_color,
      bg_class: bg_class,
      text_color: text_color,
      font_size: font_size,
      border_color: border_color,
      layout: layout,
      status: status,
      audio_url: audio_url,
      audio: audio_url,
      next_words: next_words,
      data: data,
      predictive_board_id: predictive_board_id,
      can_edit: viewing_user == board.user,
    }
  end

  def description
    image.image_prompt || board.description
  end

  def set_defaults
    audio_file = nil
    if image.use_custom_audio
      self.voice = image.voice
      audio_file = image.find_custom_audio_file
    else
      self.voice = board.voice

      audio_file = image.find_audio_for_voice(voice)
    end

    self.bg_color = image.bg_color
    self.text_color = image.text_color
    self.font_size = image.font_size
    self.border_color = image.border_color
    self.label = image.label
    self.display_image_url = image.display_image_url(user)
    if audio_file
      self.audio_url = image.default_audio_url(audio_file)
    else
      image.start_create_all_audio_job unless Rails.env.test? || Rails.env.development?
    end
    default_next_board = image.matching_viewer_boards(board.user).first
    self.predictive_board_id = default_next_board.id if default_next_board
  end

  def save_defaults
    set_defaults
    save
  end

  def set_position
    self.position = board_images.count + 1
  end

  def get_coordinates_for_screen_size(screen_size)
    layout[screen_size].slice("x", "y")
  end

  def save_initial_layout
    if self.skip_initial_layout == true
      puts "Skipping initial layout"
      return
    end
    if self.layout.blank?
      if image.image_type == "Menu"
        board.rearrange_images
      else
        self.update!(layout: initial_layout)
      end
    end
  end

  def update_layout(layout, screen_size)
    self.layout[screen_size] = layout
    save
  end

  def added_at
    created_at.strftime("%m/%d %I:%M %p")
  end

  def image_last_added_at
    image.docs.last&.created_at&.strftime("%m/%d %I:%M %p")
  end
end
