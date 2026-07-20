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
#  border_width        :integer          default(0), not null
#  border_radius       :integer          default(0), not null
#
class BoardImage < ApplicationRecord
  default_scope { order(position: :asc) }
  belongs_to :board, counter_cache: true, touch: true
  belongs_to :image
  belongs_to :predictive_board, class_name: "Board", optional: true
  has_many_attached :audio_files
  has_one_attached :video_clip
  attr_accessor :skip_create_voice_audio, :skip_initial_layout, :src

  # Formats the web player handles as-is, so they can be stored untouched if
  # ffmpeg isn't around to transcode.
  ALLOWED_VIDEO_CONTENT_TYPES = %w[video/mp4 video/webm].freeze
  # Formats we only accept because ffmpeg can convert them — iPhone recordings
  # arrive as HEVC-in-.mov, which Chrome and Firefox won't play.
  TRANSCODABLE_VIDEO_CONTENT_TYPES = %w[video/quicktime].freeze

  # Cap on what's stored and served when there's no transcode step.
  MAX_VIDEO_BYTES = 25.megabytes
  # Cap on what's accepted for transcoding. Higher because it applies to the
  # raw upload: a 30s iPhone .mov runs 40-80 MB and shrinks to a few MB once
  # it's been through ffmpeg.
  MAX_VIDEO_SOURCE_BYTES = 100.megabytes

  MAX_VIDEO_DURATION_SECONDS = 30

  # Content types accepted by upload_video right now. Depends on whether the
  # binaries are present: never accept a format we can't guarantee we can make
  # web-safe.
  def self.accepted_video_content_types
    return ALLOWED_VIDEO_CONTENT_TYPES unless VideoTranscoder.available?
    ALLOWED_VIDEO_CONTENT_TYPES + TRANSCODABLE_VIDEO_CONTENT_TYPES
  end

  def self.max_video_upload_bytes
    VideoTranscoder.available? ? MAX_VIDEO_SOURCE_BYTES : MAX_VIDEO_BYTES
  end

  before_create :set_defaults
  # before_save :save_display_image_url, if: -> { display_image_url.blank? }
  before_save :check_predictive_board
  before_update :set_colors, if: :part_of_speech_changed?
  # after_create_commit (not after_create): tiles are often created inside a
  # larger transaction (Board Builder clones a whole linked set in one), and
  # an after_create enqueue lets Sidekiq run SaveAudioJob before the commit —
  # the job can't find the row ("BoardImage with ID ... not found") and the
  # tile ends up with no audio_url.
  after_create_commit :create_voice_audio_after_create, unless: -> { skip_create_voice_audio }

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
    lang = (language || board&.language || "en").to_s
    # language_settings is a jsonb column with string keys (see Image#translate_to)
    image_language_settings = (image.language_settings || {})[lang] || {}
    self.language = lang
    self.label = image_language_settings["label"] || image.label
    self.display_label = image_language_settings["display_label"] || label
  end

  # Delegates to the underlying Image's language_settings. Stored `label` /
  # `display_label` columns reflect the board's authored language; this resolves
  # the viewer's preferred language at read time.
  def localized_label(lang)
    return label if lang.blank? || lang.to_s == (language.presence || "en")
    image&.localized_label(lang) || label
  end

  def localized_display_label(lang)
    return display_label if lang.blank? || lang.to_s == (language.presence || "en")
    image&.localized_display_label(lang) || display_label
  end

  def hide_label
    data && data["hide_label"] == true
  end

  def is_dynamic?
    predictive_board_id.present? && predictive_board_id != board_id
  end

  def reset_part_of_speech_and_bg_color!
    reset_part_of_speech!
    set_colors!
    pos = part_of_speech
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

  def save_display_image_url
    display_image_url = image.display_tile_url(user)
    Rails.logger.debug "Saving display_image_url for BoardImage ID #{id}: #{display_image_url}"
    self.update_column(:display_image_url, display_image_url)
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

  def tile_image_url(viewing_user = nil)
    display_image_url.presence ||
      image.display_tile_url(viewing_user) ||
      image.display_image_url(viewing_user) ||
      image.src_url.presence ||
      Image.find_by(label: image.label, user_id: [nil, User::DEFAULT_ADMIN_ID])&.src_url
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
    {
      id: id.to_s,
      url: tile_image_url(viewing_user),
      content_type: image.content_type,
      ext_saw_label: label,
      ext_saw_voice: voice,
      ext_board_type: board.board_type,
    }.compact
  end

  # Returns nil when there's no audio file to point at — caller compacts these.
  # OBF requires each sound to have a unique id, so emitting an empty id is invalid.
  def to_obf_sound_format
    return nil if audio_url.blank?
    {
      id: id.to_s,
      url: audio_url,
      content_type: "audio/aac",
      ext_saw_label: label,
      ext_saw_voice: voice,
      ext_board_type: board.board_type,
      ext_saw_image_id: id.to_s,
    }
  end

  def to_obf_button_format
    btn = {
      id: id.to_s,
      label: label,
      image_id: id.to_s,
      background_color: get_background_color_css,
      border_color: border_color || "rgb(68, 68, 68)",
      ext_saw_image_id: image_id.to_s,
      ext_saw_board_id: board_id.to_s,
    }
    btn[:sound_id] = id.to_s if audio_url.present?
    if (video = video_config)
      btn[:ext_saw_video_source] = video["source"]
      btn[:ext_saw_video_youtube_id] = video["youtube_id"] if video["youtube_id"].present?
      btn[:ext_saw_video_url] = video["url"] if video["url"].present?
    end
    if predictive_board_id
      target = Board.find_by(id: predictive_board_id)
      if target
        btn[:load_board] = {
          id: (target.obf_id.presence || target.id.to_s),
          name: target.name,
        }
      end
    end
    btn
  end

  def create_voice_audio
    current_audio_url = audio_url_for_voice(voice, language)
    unless current_audio_url
      SaveAudioJob.perform_async(image_id, voice, id)
      return
    end
    self.audio_url = current_audio_url
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

  def default_doc_url(reset = false)
    viewing_user = reset ? nil : user
    image.display_tile_url(viewing_user)
  end

  def display_doc(reset = false)
    viewing_user = reset ? nil : user
    image.display_doc(viewing_user)
  end

  def default_doc_processed?
    doc = display_doc(true)
    doc && doc.tile_variant_processed?
  end

  def url_needs_update?
    return true if display_image_url.blank?
    old_src = image.display_image_url(user)
    if display_image_url == old_src
      return true
    end
  end

  def update_to_default_doc!
    new_url = default_doc_url(true)
    if new_url.blank? || new_url == display_image_url
      return
    end
    display_image_url = new_url
    self.update_column(:display_image_url, display_image_url)
  end

  # def update_to_user_doc!(viewing_user)
  #   new_url = default_doc_url(false)
  #   if new_url.blank? || new_url == display_image_url
  #     return
  #   end
  #   display_image_url = new_url
  #   self.update_column(:display_image_url, display_image_url)
  # end

  def api_view(viewing_user = nil)
    viewer_lang = viewing_user.respond_to?(:i18n_locale) ? viewing_user.i18n_locale.to_s : nil
    {
      id: id,
      image_id: image_id,
      label: localized_label(viewer_lang),
      display_label: localized_display_label(viewer_lang),
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
      border_width: border_width,
      border_radius: border_radius,
      frozen_board: board.is_frozen?,
      audio_files: all_audio_files_for_api_plus_image_audio,
      docs: image.docs.for_user(viewing_user).order(created_at: :desc).limit(10).map { |doc| doc.list_api_view(viewing_user) },
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
      language_settings: language_settings,
    # image_audio_files: image_audio_files,
    # remaining_user_boards: remaining_user_boards,
    }
  end

  def index_view(viewing_user = nil)
    viewer_lang = viewing_user.respond_to?(:i18n_locale) ? viewing_user.i18n_locale.to_s : nil
    {
      id: id,
      image_id: image_id,
      label: localized_label(viewer_lang),
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
      display_label: localized_display_label(viewer_lang),
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

  # --- Tile video (data["video"]) -------------------------------------------
  # Video config lives inside the `data` jsonb under a single "video" key:
  #   { "source" => "youtube", "youtube_id" => "...",
  #     "start_seconds" => 45, "end_seconds" => 72 }   # trim points optional
  #   { "source" => "upload",  "url" => "<cdn url>", "content_type" => "video/mp4" }
  # It is only ever written by the dedicated controller actions
  # (attach_youtube_video / upload_video / clear_video) — the generic update
  # path strips the key so unvalidated client input can't reach it.

  # Optional trim points for a tile video, in whole seconds (the YouTube embed
  # API takes no fractional values). Both bounds are independently optional.
  #
  # Returns a hash containing whichever bounds were supplied — {} when neither
  # was — or nil when the supplied values don't describe a usable range. The
  # caller must distinguish those: {} means "no trim", nil means "reject".
  def self.parse_video_range(start_raw, end_raw)
    parsed = {}
    { "start_seconds" => start_raw, "end_seconds" => end_raw }.each do |key, raw|
      next if raw.blank?
      digits = raw.to_s.strip
      return nil unless digits.match?(/\A\d+\z/)
      parsed[key] = digits.to_i
    end
    if parsed.key?("start_seconds") && parsed.key?("end_seconds")
      return nil unless parsed["end_seconds"] > parsed["start_seconds"]
    end
    parsed
  end

  def video_config
    data&.dig("video").presence
  end

  def video?
    video_config.present?
  end

  def set_youtube_video!(youtube_id, range = {})
    video_clip.purge_later if video_clip.attached?
    config = { "source" => "youtube", "youtube_id" => youtube_id }.merge(range)
    self.data = (data || {}).merge("video" => config)
    save!
  end

  # `processed` tracks whether ProcessTileVideoJob has run: false right after
  # upload (the URL still points at the raw file), true once the clip is known
  # to be within the duration cap and in a web-safe container. It also makes
  # the job idempotent, so a Sidekiq retry can't transcode twice.
  def set_uploaded_video!(url, content_type, duration: nil, processed: false)
    config = { "source" => "upload", "url" => url, "content_type" => content_type, "processed" => processed }
    config["duration"] = duration.round(2) if duration
    self.data = (data || {}).merge("video" => config)
    save!
  end

  def video_processed?
    video_config&.dig("processed") == true
  end

  def clear_video!
    video_clip.purge_later if video_clip.attached?
    self.data = (data || {}).except("video")
    save!
  end

  # CDN-aware URL for the attached clip — same resolution scheme as
  # AudioHelper#default_audio_url so playback URLs are stable and cacheable.
  def video_clip_url
    blob = video_clip.attached? ? video_clip.blob : nil
    return nil unless blob
    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      "#{ENV["CDN_HOST"]}/#{blob.key}"
    else
      video_clip.url
    end
  end

  def has_custom_audio?
    audio_files.any? { |af| af.blob.filename.to_s.include?("custom") }
  end

  def using_custom_audio?
    data && data["using_custom_audio"] == true && has_custom_audio?
  end

  def set_defaults
    audio_file = nil
    self.voice = board.voice
    self.language = board.language
    self.display_label = image.display_label if display_label.blank?
    self.language_settings = image.language_settings

    # audio_file = image.find_audio_for_voice(voice, language)
    # end
    img_color = image.bg_color || "white"
    set_background_color(img_color) if bg_color.blank?
    self.font_size = image.font_size
    self.label = image.label
    # self.display_image_url = image.display_tile_url(user)
    self.display_image_url = image.src_url
    self.next_words = image.next_words || []
    # Respect a part_of_speech that was explicitly set before create (e.g. a
    # clone via Board#clone_with_images dup'ing a seeded tile, #279) — only
    # fall back to the shared Image's value when this record carries none.
    # New records get the column default ("default"), which counts as "none".
    if part_of_speech.blank? || part_of_speech == "default"
      self.part_of_speech = image.part_of_speech || "default"
    end
  end

  def create_voice_audio_after_create
    current_audio_url = audio_url_for_voice(voice, language)
    unless current_audio_url
      SaveAudioJob.perform_async(image_id, voice, id)
      return
    end
    self.audio_url = current_audio_url
    save
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
