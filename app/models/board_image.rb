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
#  language            :string           default("en")
#  display_label       :string
#  language_settings   :jsonb
#  hidden              :boolean          default(FALSE)
#  part_of_speech      :string           default("default"), not null
#
class BoardImage < ApplicationRecord
  default_scope { order(position: :asc) }
  belongs_to :board, counter_cache: true, touch: true
  belongs_to :image
  belongs_to :predictive_board, class_name: "Board", optional: true
  has_many_attached :audio_files
  attr_accessor :skip_create_voice_audio, :skip_initial_layout, :src

  before_create :set_defaults
  # before_save :save_display_image_url, if: -> { display_image_url.blank? }
  before_save :check_predictive_board
  before_save :set_colors, if: :part_of_speech_changed?

  include BoardsHelper
  include ImageHelper
  include AudioHelper
  include ColorHelper

  scope :updated_today, -> { where("updated_at > ?", 1.hour.ago) }
  scope :with_artifacts, -> { includes({ predictive_board: [{ board_images: :image }] }, :image, :board) }
  scope :visible, -> { where(hidden: false) }
  scope :hidden, -> { where(hidden: true) }
  scope :created_today, -> { where("created_at >= ?", Time.zone.now.beginning_of_day) }

  delegate :user_id, to: :board, allow_nil: false

  def set_initial_layout!
    self.layout = { "lg" => { "i" => id.to_s, "x" => grid_x("lg"), "y" => grid_y("lg"), "w" => 1, "h" => 1 },
                    "md" => { "i" => id.to_s, "x" => grid_x("md"), "y" => grid_y("md"), "w" => 1, "h" => 1 },
                    "sm" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
                    "xs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 },
                    "xxs" => { "i" => id.to_s, "x" => grid_x("sm"), "y" => grid_y("sm"), "w" => 1, "h" => 1 } }
    self.save
  end

  def open_ai_opts
    {
      prompt: label,
    }
  end

  def set_background_color(value)
    self.bg_color = ColorHelper.to_hex(value, default: "#FFFFFF")
    self.text_color ||= ColorHelper.text_hex_for(bg_color)
  end

  def set_background_color!
    pos = part_of_speech || image.part_of_speech || "default"
    img_color = background_color_for(pos)
    set_background_color(img_color)
    self.save!
  end

  def set_text_color(value)
    self.text_color = ColorHelper.to_hex(value, default: "#000000")
  end

  def set_text_color!
    set_text_color(image.text_color || "black")
  end

  def set_colors!
    set_background_color!
  end

  # NO save
  def set_colors
    set_text_color("black") unless text_color == "#000000"
    pos = part_of_speech || image.part_of_speech || "default"
    img_color = background_color_for(pos)
    set_background_color(img_color)
  end

  def set_labels
    lang = language || board.language || "en"
    image_language_settings = image.language_settings[lang.to_sym] || {}
    self.language = lang
    self.label = image_language_settings[:label] || image.label
    self.display_label = image_language_settings[:display_label] || label
  end

  def is_dynamic?
    predictive_board_id.present? && predictive_board_id != board_id
  end

  def reset_part_of_speech_and_bg_color!
    reset_part_of_speech!
    set_colors!
    pos = part_of_speech
    puts "Reset part_of_speech to #{pos} and bg_color to #{bg_color} for BoardImage ID #{id}"
    #  update image
    self.save!
    image.update_column(:part_of_speech, pos)
    image.set_background_color!(pos)
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

  def save_display_image_url
    self.display_image_url = image.src_url
  end

  def self.with_invalid_layouts
    self.includes(:board).all.select { |bi| bi.layout_invalid? }
  end

  def self.with_non_cdn_audio
    self.includes(:image).all.select { |bi| bi.audio_url && !bi.audio_url.include?("cloudfront") }
  end

  def self.fix_non_cdn_audio(limit = 100)
    # This method will fix all board images that have audio URLs not using CDN
    # It will set the audio_url to the default audio URL for the image and voice
    # This is useful for images that were created before CDN was implemented
    # or if the audio file was not created correctly.
    broken_records = self.with_non_cdn_audio
    puts "There are #{broken_records.count} board images with non-CDN audio URLs"
    puts "Do you want to fix them? (y/n)"
    answer = STDIN.gets.chomp
    unless answer.downcase == "y"
      puts "Aborting fix."
      return
    end
    count = 0
    broken_records.each do |bi|
      img = bi.image
      voice = bi.voice
      lang = bi.language
      audio_file = img.find_audio_for_voice(voice, lang)

      bi.audio_url = img.default_audio_url(audio_file)
      bi.save
      count += 1
      break if count >= limit
    end
    puts "Fixed #{count} board images with non-CDN audio URLs"
  end

  def self.fix_invalid_layouts
    self.with_invalid_layouts.each do |bi|
      bi.set_initial_layout!
    end
  end

  def self.fix_bg_hex
    self.all.each do |bi|
      next if bi.bg_color.nil? || bi.bg_color.start_with?("#")
      bi.set_background_color!
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

  def bg_hex
    ColorHelper.to_hex(bg_color, default: "#FFFFFF")
  end

  def display_image_url_or_default(viewing_user = nil)
    display_image_url || image.display_image_url(viewing_user) || image.src_url
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
    return "bg-white" if bg_color.blank?
    bg_color = self.bg_color || "white"
    color = bg_color.include?("bg-") ? bg_color : "bg-#{bg_color}-400"
    color || "bg-#{image.bg_class}-400" || "bg-white"
  end

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
    audio_file = image.find_audio_for_voice(voice, language)
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
    image.find_audio_for_voice(voice, language)
  end

  def create_voice_audio
    return if @skip_create_voice_audio || Rails.env.test?
    label_voice = "#{image.label_for_filename}_#{voice}"
    if language != "en"
      label_voice = "#{label_voice}_#{language}"
    end
    filename = "#{label_voice}.mp3"
    already_has_audio_file = image.existing_audio_files.include?(filename)
    self.voice = voice
    self.language = language
    audio_file = image.find_audio_for_voice(voice, language)

    if already_has_audio_file && audio_file
      self.audio_url = image.default_audio_url(audio_file)
    else
      find_or_create_audio_file_for_voice(voice, language)
      audio_file = find_audio_for_voice(voice, language)
      self.audio_url = default_audio_url(audio_file)
    end
    @skip_create_voice_audio = true
    save
  end

  def user
    board.user
  end

  def override_frozen
    return unless board.is_frozen?
    # override_frozen = @board_image.data["override_frozen"] == true
    data = self.data || {}
    data["override_frozen"] == true
  end

  def image_audio_files
    image.audio_files_for_api(audio_url)
  end

  def all_audio_files_for_api_plus_image_audio
    all_audio_files_for_api(audio_url) + image_audio_files
  end

  def voice_list
    img_existing_voices = image.existing_voices
    all_voices = img_existing_voices + existing_voices
    all_voices.uniq
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      image_id: image_id,
      label: label,
      display_label: display_label,
      part_of_speech: part_of_speech,
      image_prompt: image_prompt,
      user_id: board.user_id,
      hidden: hidden,
      board_name: board.name,
      board_type: board.board_type,
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
      frozen_board: board.is_frozen?,
      audio_files: all_audio_files_for_api_plus_image_audio,
      voice_list: voice_list,
      layout: layout,
      status: status,
      audio_url: audio_url,
      audio: audio_url,
      next_words: next_words,
      data: data,
      predictive_board_id: predictive_board_id,
      predictive_board_name: predictive_board&.name,
      can_edit: viewing_user == board.user,
      language: language,
      display_label: display_label,
      language_settings: language_settings,
    # image_audio_files: image_audio_files,
    # remaining_user_boards: remaining_user_boards,
    }
  end

  def index_view(viewing_user = nil)
    {
      id: id,
      image_id: image_id,
      label: label,
      board_id: board_id,
      board_name: board.name,
      board_type: board.board_type,
      dynamic: is_dynamic?,
      can_edit: viewing_user == board.user,
      voice: voice,
      hidden: hidden,
      part_of_speech: part_of_speech,
      audio_files: audio_files.map { |af| { id: af.id, url: af.to_s, content_type: af.inspect } },
      # predictive_board_id: predictive_board_id,
      display_label: display_label,
      bg_color: bg_color,
      bg_class: bg_class,
      display_image_url: display_image_url,
      predictive_board_name: predictive_board&.name,
    }
  end

  # def remaining_user_boards
  #   user_boards = user.boards
  #   image_boards = image.board_images.map(&:board)
  #   remaining = user_boards.where.not(id: image_boards.map(&:id))
  #   remaining
  # end

  def description
    image.image_prompt || board.description
  end

  def has_custom_audio?
    audio_files.any? { |af| af.blob.filename.to_s.include?("custom") }
  end

  def using_custom_audio?
    data ||= {}
    data["using_custom_audio"] == true
  end

  def set_defaults
    audio_file = nil
    if image.use_custom_audio
      self.voice = image.voice
      audio_file = image.find_custom_audio_file
    else
      self.voice = board.voice
      self.language = board.language
      self.display_label = image.display_label if display_label.blank?
      self.language_settings = image.language_settings

      audio_file = image.find_audio_for_voice(voice, language)
    end
    img_color = image.bg_color || "white"
    set_background_color(img_color) if bg_color.blank?
    self.font_size = image.font_size
    self.border_color = image.border_color
    self.label = image.label
    self.display_image_url = image.display_image_url(user)
    self.next_words = image.next_words || []
    if audio_file
      self.audio_url = image.default_audio_url(audio_file)
    else
      image.start_create_all_audio_job(language) unless Rails.env.test? || Rails.env.development?
    end
    if board.board_type != "static"
      default_next_board = image.matching_viewer_boards(board.user).first
      self.predictive_board_id = default_next_board.id if default_next_board
    end
  end

  def save_defaults
    set_defaults
    save
  end

  def set_position
    self.position = board_images_count + 1
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

  def create_image_edit!(prompt, transparent_bg = false)
    begin
      url = display_image_url || image.src_url
      Rails.logger.debug "Creating image edit for board_image ID #{id} with URL: #{url}"
      if transparent_bg
        prompt_with_bg = "#{prompt} with a transparent background"
        prompt = prompt_with_bg
      end
      image_url = image.generate_image_edit(url, user_id, prompt)
      if image_url.nil?
        Rails.logger.error "Failed to create image edit for board_image ID #{id}"
        return nil
      end
      Rails.logger.debug "Created image edit with ID #{image_url.class}"
      # strip quotes if present
      url = image_url.gsub(/^"|"$/, "")
      Rails.logger.debug "Generated image edit URL: #{url}"
      self.display_image_url = url
      self.save!
      return url
    rescue => e
      Rails.logger.error "Error creating image edit: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      return nil
    end
  end

  def create_image_variation!
    begin
      url = display_image_url || image.src_url
      Rails.logger.debug "Creating image variation for board_image ID #{id} with URL: #{url}"
      image_url = image.generate_image_variation(url, user_id)

      if image_url.nil?
        Rails.logger.error "Failed to create image variation for board_image ID #{id}"
        return nil
      end
      Rails.logger.debug "Created image variation with ID #{image_url.class}"
      Rails.logger.debug "Generated image variation URL: #{image_url}"
      url = image_url
      Rails.logger.debug "Generated image variation URL: #{url}"
      self.display_image_url = url
      self.save!
      return url
    rescue => e
      Rails.logger.error "Error creating image variation: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      return nil
    end
  end

  def describe_image(doc_url)
    begin
      response = OpenAiClient.new(open_ai_opts).describe_image(doc_url)
      Rails.logger.debug "Response: #{response}"
      response_content = response.dig("choices", 0, "message", "content").strip
      Rails.logger.debug "Response content: #{response_content}"
      self.data ||= {}
      self.data["image_description_generated_at"] = Time.current
      self.data["image_description"] = response_content
      self.save!
    rescue => e
      Rails.logger.error "Error describing image: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      response_content = nil
    end
    response_content
  end
end
