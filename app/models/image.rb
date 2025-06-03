# == Schema Information
#
# Table name: images
#
#  id                  :bigint           not null, primary key
#  label               :string
#  image_prompt        :text
#  display_description :text
#  private             :boolean
#  user_id             :integer
#  generate_image      :boolean          default(FALSE)
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  status              :string
#  error               :string
#  revised_prompt      :string
#  image_type          :string
#  open_symbol_status  :string           default("active")
#  next_words          :string           default([]), is an Array
#  no_next             :boolean          default(FALSE)
#  part_of_speech      :string
#  bg_color            :string
#  text_color          :string
#  font_size           :integer
#  border_color        :string
#  is_private          :boolean          default(FALSE)
#  audio_url           :string
#  category            :string
#  use_custom_audio    :boolean          default(FALSE)
#  voice               :string
#  src_url             :string
#  data                :jsonb
#  license             :jsonb
#  obf_id              :string
#  language_settings   :jsonb
#  language            :string           default("en")
#
class Image < ApplicationRecord
  paginates_per 100
  normalizes :label, with: ->label { label.downcase.strip }
  attr_accessor :temp_prompt
  belongs_to :user, optional: true
  has_many :docs, as: :documentable, dependent: :destroy
  has_many :board_images, dependent: :destroy
  has_many :boards, through: :board_images
  has_many_attached :audio_files
  has_many :predictive_boards, as: :parent, class_name: "Board", dependent: :destroy
  has_many :category_boards, class_name: "Board", foreign_key: "image_parent_id", dependent: :destroy

  accepts_nested_attributes_for :docs

  PROMPT_ADDITION = " Styled as a simple cartoon illustration."

  SOURCE_TYPE_NAMES = ["CommuniKate", "Core 24 - ", "Core 24", "Sequoia 15 - ", "Sequoia 15", "starter, "].freeze

  validates :label, presence: true

  include ImageHelper
  include Rails.application.routes.url_helpers
  include PgSearch::Model
  pg_search_scope :search_by_label, against: :label, using: { tsearch: { prefix: true } }

  pg_search_scope :search_part_of_speech, against: :part_of_speech, using: { tsearch: { prefix: true } }
  def self.rebuild_pg_search_documents
    find_each { |record| record.update_pg_search_document }
  end

  scope :without_attached_audio_files, -> { where.missing(:audio_files_attachments) }
  # scope :searchable, -> { non_sample_voices.non_menu_images.where(obf_id: nil) }
  # scope :searchable, -> { non_sample_voices.non_menu_images }
  scope :searchable, -> { non_sample_voices }
  scope :with_image_docs_for_user, ->(userId) { order(created_at: :desc) }
  scope :menu_images, -> { where(image_type: ["menu", "Menu"]) }
  scope :non_menu_images, -> { where.not(image_type: ["menu", "Menu"]).or(where(image_type: nil)) }
  scope :non_scenarios, -> { where.not(image_type: "OpenaiPrompt").or(where(image_type: nil)) }
  scope :non_sample_voices, -> { where.not(image_type: "SampleVoice").or(where(image_type: nil)) }
  scope :sample_voices, -> { where(image_type: "SampleVoice") }
  scope :no_image_type, -> { where(image_type: nil) }
  scope :public_img, -> { non_sample_voices.where(private: [false, nil]) }
  scope :private_img, -> { where(private: true) }
  scope :created_in_last_2_hours, -> { where("created_at > ?", 2.hours.ago) }
  scope :skipped, -> { where(open_symbol_status: "skipped") }
  scope :active, -> { where(open_symbol_status: "active") }
  scope :without_docs, -> { where.missing(:docs) }
  scope :with_docs, -> { where.associated(:docs) }
  scope :generating, -> { where(status: "generating") }
  scope :with_artifacts, -> { includes({ docs: { image_attachment: :blob } }, :predictive_boards, :user, :category_boards) }
  scope :created_between, ->(start_date, end_date) { where(created_at: start_date..end_date) }
  scope :created_before, ->(date) { where("created_at < ?", date) }

  scope :with_less_than_3_docs, -> { joins(:docs).group("images.id").having("count(docs.id) < 3") }
  after_create :categorize!, unless: :menu?
  before_save :set_label, :ensure_defaults
  before_save :clean_up_label, if: -> { !obf_id.blank? }

  after_save :update_board_images_audio, if: -> { need_to_update_board_images_audio? }
  after_save :update_board_images_display_image, if: -> { src_url_changed? }
  after_save :update_board_images_next_words, if: -> { next_words_changed? }
  after_save :update_background_color, if: -> { part_of_speech_changed? }
  after_save :update_category_boards

  before_save :update_src_url, if: -> { src_url.blank? && docs.any? }

  scope :menu_images_without_docs, -> { menu_images.without_docs }

  def need_to_update_board_images_audio?
    use_custom_audio || voice_changed?
  end

  def update_category_boards
    if category_boards.any?
      category_boards.each do |board|
        board.update!(display_image_url: src_url)
      end
    end
  end

  def update_board_images_display_image
    board_images.each do |bi|
      bi.update!(display_image_url: src_url) if bi.display_image_url.blank?
    end
  end

  def update_board_images_next_words
    board_images.each do |bi|
      bi.update!(next_words: next_words) if bi.next_words.blank?
    end
  end

  def update_board_images_audio
    BoardImage.where(image_id: id).each do |bi|
      bi.update!(audio_url: audio_url, voice: voice)
    end
  end

  def source_type
    data = self.data || {}
    data["source_type"]
  end

  def clean_up_label
    has_source_type = false
    original_type_name = nil
    img_label = label
    SOURCE_TYPE_NAMES.each do |type_name|
      img_label = label.downcase
      type_name.downcase!
      has_source_type = img_label.include?(type_name)

      if has_source_type
        original_type_name = type_name
        img_label.gsub!(type_name, "")
        break
      end
    end
    self.data ||= {}
    self.data["source_type"] = original_type_name if has_source_type
    self.label = img_label.strip

    if label.blank? || label == "Untitled Image"
      self.label = original_type_name + " Image" if original_type_name
      if label.blank?
        self.name = "Untitled Image"
      end
    end
  end

  def predictive_board
    # if predictive_board_id
    #   board = Board.find_by(id: predictive_board_id)
    #   return board if board
    # end
    # matching_boards = matching_viewer_boards(user)
    # matching_boards.order(created_at: :desc).first if matching_boards.any?

  end

  #   require 'net/http'
  # require 'uri'

  def authorized_to_view_url?(url)
    begin
      uri = URI.parse(url)
      response = Net::HTTP.get_response(uri)

      # Allowable status codes (you can customize this)
      return response.code.to_i == 200
    rescue SocketError, URI::InvalidURIError, Timeout::Error, Errno::ECONNREFUSED => e
      Rails.logger.error("URL validation error for #{url}: #{e.message}")
      return false
    end
  end

  def update_all_boards_image_belongs_to(url = nil, override_existing = false, current_user_id = nil)
    updated_ids = []
    board_images.includes(:board).find_each do |bi|
      if current_user_id && (bi.board.user_id != current_user_id) && bi.board.user_id != User::DEFAULT_ADMIN_ID
        next
      end
      original_url = bi.display_image_url

      if bi.display_image_url.present? && !override_existing
        is_current_url_valid = authorized_to_view_url?(bi.display_image_url)
        if is_current_url_valid
          next
        else
          image_result = authorized_to_view_url?(url)
          bi.display_image_url = url if image_result
        end
      else
        bi.display_image_url = url if authorized_to_view_url?(url)
      end

      if bi.save
        updated_ids << bi.id
        if !bi.board.display_image_url.blank? && original_url === bi.board.display_image_url
          bi.board.display_image_url = url
        end
        bi.board.updated_at = Time.now
        bi.board.save!
      else
        puts "Error saving board image #{bi.id} - #{bi.board.name} - #{bi.errors.full_messages}"
      end
    end
    updated_ids
  end

  def self.category
    # self.where.associated(:category_boards)
    self.where(image_type: "category")
  end

  def self.static
    self.where.not(image_type: ["category", "predictive"])
  end

  def self.predictive
    self.where(image_type: "predictive")
  end

  def self.update_all_background_colors
    bad_bg_colors = ["gray", "white", nil]
    self.where(bg_color: bad_bg_colors).each do |image|
      image.update_background_color
    end
  end

  def update_background_color
    self.bg_color = background_color_for(part_of_speech)
    self.text_color = text_color_for(bg_color)
    self.save!
    board_images.each do |bi|
      bi.update!(bg_color: bg_color, text_color: text_color)
    end
  end

  def ensure_defaults
    if image_type == "menu"
      self.part_of_speech = "noun"
    else
      self.bg_color = background_color_for(part_of_speech) if part_of_speech_changed?
      self.text_color = text_color_for(bg_color) if text_color.blank?
    end
    if audio_url.blank?
      self.audio_url = default_audio_url
    end

    if voice.blank?
      user_voice = user&.voice
      self.voice = user_voice || "alloy"
    end

    if image_type.blank? && predictive_boards.any?
      self.image_type = "predictive"
    end

    if image_type.blank? || image_type == "Static"
      self.image_type = "static"
      Rails.logger.debug "Would have set image type to Static for #{label}"
    end
  end

  def should_generate_symbol?
    return false if image_type == "menu"
    label_changed? && open_symbol_status == "active"
  end

  def should_set_next_words?
    return false if image_type == "menu"
    return true if next_words.blank? && no_next == false
    words_to_check = next_words - [label]
    if words_to_check.blank?
      return true
    end
  end

  def run_set_next_words_job
    Rails.logger.debug "Starting set next words job for #{label}"
    SetNextWordsJob.perform_async([id])
  end

  def create_predictive_board(new_user_id, words_to_use = nil, use_preview_model = false, board_settings = {})
    Rails.logger.debug "Creating predictive board for #{label} - #{new_user_id} - words: #{words_to_use}"
    new_board = false
    base_board_id = board_settings[:board_id]
    if base_board_id
      base_board = Board.find_by(id: base_board_id)
    end
    board = predictive_boards.find_by(name: label, user_id: new_user_id) unless board
    if board
      if use_preview_model && words_to_use.blank?
        board_words = board.board_images.map(&:label).uniq
        self.next_words = board.get_words(name_to_send, 10, board_words, use_preview_model)
      end

      # board.find_or_create_images_from_word_list(words_to_use)
    else
      Rails.logger.debug "Creating new predictive board for #{label} - #{new_user_id} - settings: #{board_settings}"
      board = predictive_boards.create!(name: label, user_id: new_user_id, settings: board_settings)
      new_board = true
      if use_preview_model && words_to_use.blank?
        board_words = board.board_images.map(&:label).uniq
        self.next_words = board.get_words(name_to_send, 10, board_words, use_preview_model)
      end
    end

    if !board
      Rails.logger.debug "Could not create predictive board for #{label}"
      return
    end
    new_base_board_image = base_board.add_image(self.id) if base_board
    board.update!(display_image_url: src_url) if src_url

    self.image_type = "predictive"
    if new_base_board_image
      new_base_board_image.predictive_board_id = board.id
      new_base_board_image.save!
      base_board.update!(board_type: "dynamic")
    end

    board.find_or_create_images_from_word_list(words_to_use)
    board.board_type = "predictive"
    board.reset_layouts if new_board
    board
  end

  def self.valid_parts_of_speech
    ["noun", "verb", "adjective", "adverb", "pronoun", "preposition", "conjunction", "interjection", "phrase", "article"]
  end

  def self.ensure_parts_of_speech(limit = 100)
    imgs = Image.where.not(part_of_speech: Image.valid_parts_of_speech).or(Image.where(part_of_speech: nil))
    total_without_part_of_speech = imgs.count
    puts "Total images without part of speech: #{total_without_part_of_speech} - limit: #{limit} \nContinue? (y/n)"
    response = gets.chomp
    return unless response == "y"
    images_without_part_of_speech = imgs.limit(limit)
    puts "Images without part of speech: #{images_without_part_of_speech.count} - labels: #{images_without_part_of_speech.pluck(:label)}\n\n"
    images_without_part_of_speech.each do |image|
      image.categorize!
    end
  end

  def background_color_for(category)
    color = "gray"
    case category
    when "noun"
      color = "blue"
    when "verb"
      color = "green"
    when "adjective"
      color = "yellow"
    when "adverb"
      color = "purple"
    when "pronoun"
      color = "pink"
    when "preposition"
      color = "orange"
    when "conjunction"
      color = "red"
    when "interjection"
      color = "teal"
    when "phrase"
      color = "white"
    else
      color = "gray"
    end
    color
  end

  def text_color_for(bg_color)
    color = "black"
    case bg_color
    when "blue"
      color = "white"
    when "green"
      color = "white"
    when "yellow"
      color = "black"
    when "purple"
      color = "white"
    when "pink"
      color = "black"
    when "orange"
      color = "black"
    when "red"
      color = "white"
    when "teal"
      color = "white"
    when "gray"
      color = "white"
    else
      color = "black"
    end
    color
  end

  def resource_type
    "Image"
  end

  def bg_class
    return "bg-white" if bg_color.blank? || bg_color == "white"
    bg_color = self.bg_color || "gray"
    color = bg_color.include?("bg-") ? bg_color : "bg-#{bg_color}-400"
    color || "bg-#{image.bg_class}-400" || "bg-white"
  end

  def create_image_doc(user_id = nil)
    response = create_image(user_id)
    if response
      doc = response
      doc.update_user_docs
      doc.update!(current: true)
      doc
    end
  end

  def should_create_audio_files?
    audio_files.count < Image.voices.count
  end

  def name
    label
  end

  def start_create_all_audio_job(language_to_use = "en")
    CreateAllAudioJob.perform_async(id, language_to_use)
  end

  def create_voice_audio_files(language_to_use = "en")
    Image.voices.each do |voice|
      voice_file = find_audio_for_voice(voice, language_to_use)
      if voice_file
        puts "Audio file found for #{label} - #{voice} - #{language_to_use}"
      else
        puts "Creating audio file for #{label} - #{voice} - #{language_to_use}"
        create_audio_from_text(label, voice, language_to_use)
      end
    end
  end

  def self.create_single_audio_for_images_missing(limit = 50)
    voice = "alloy"
    group_num = 0
    Image.without_attached_audio_files.find_in_batches(batch_size: 20) do |images|
      puts "\nStarting create audio job for group #{group_num} for #{images.count} images"
      SaveAudioJob.perform_async(images.pluck(:id), voice)
      group_num += 1
      puts "Sleeping for 2 seconds"
      sleep 2
      break if group_num >= limit
    end
  end

  def set_next_words!
    return if no_next || next_words.any?
    new_next_words = get_next_words(label)
    if new_next_words
      self.next_words = new_next_words
      self.save!
    else
      self.update!(no_next: true)
    end
    new_next_words
  end

  def self.run_create_words_job
    Image.public_img.non_menu_images.pluck(:id).each_slice(20) do |img_ids|
      CreateNewWordsJob.perform_async(img_ids)
    end
  end

  def self.run_set_next_words_job(limit = 40)
    count = 0
    Image.lock.public_img.non_menu_images.where(next_words: [], no_next: false).find_in_batches(batch_size: 20) do |images|
      img_ids = images.pluck(:id)

      SetNextWordsJob.perform_async(img_ids)
      count += 20
      break if count >= limit
      sleep(1)
    end
  end

  def next_images(user_id = nil)
    # imgs = Image.where(label: next_words).public_img.order(created_at: :desc).distinct(:label)
    if next_words.blank? || next_words == [label]
      return Board.predictive_default.images
    end
    imgs = []
    next_words.each do |word|
      img = Image.find_by(label: word, user_id: user_id) if user_id
      img = Image.public_img.find_by(label: word) unless img
      if img
        imgs << img
      else
        Rails.logger.debug "Image not found: #{word}"
        img = Image.create(label: word)
        if img
          imgs << img
        else
          Rails.logger.debug "Could not create image: #{word} - #{img.errors.full_messages}"
        end
      end
    end

    return imgs if imgs.any?
    Board.predictive_default.images
  end

  def create_words_from_next_words
    return unless next_words
    next_words.each do |word|
      existing_word = Image.public_img.find_by(label: word)
      if existing_word
        Rails.logger.debug "Word already exists: #{existing_word.label}"
        if existing_word.next_words.blank?
          existing_word.save!
        else
          Rails.logger.debug "Next words already set for #{existing_word.label}\n #{existing_word.next_words}"
        end
      else
        image = Image.public_img.create!(label: word)
      end
    end
  end

  def audio_file_exists_for?(voice, lang = "en")
    if lang == "en"
      audio_files_blobs.where(filename: "#{label}_#{voice}.aac").any?
    else
      audio_files_blobs.where(filename: "#{label}_#{voice}_#{lang}.aac").any?
    end
  end

  def menu?
    image_type == "menu"
  end

  def finished?
    status == "finished"
  end

  def generating?
    status == "generating"
  end

  def self.open_symbol_statuses
    ["active", "skipped"]
  end

  def no_audio_saved
    audio_files.blank?
  end

  def predictive?
    image_type == "predictive"
  end

  def default_audio_files
    audio_files.select { |audio| audio.blob.filename.to_s.exclude?("custom") }
  end

  def audio_files_for_api
    default_audio_files.map { |audio| { voice: voice_from_filename(audio&.blob&.filename&.to_s), url: default_audio_url(audio), id: audio&.id, filename: audio&.blob&.filename&.to_s, created_at: audio&.created_at, current: is_audio_current?(audio) } }
  end

  def custom_audio_files
    audio_files.select { |audio| audio.blob.filename.to_s.include?("custom") }
  end

  def custom_audio_files_for_api
    custom_audio_files.map { |audio| { voice: voice_from_filename(audio&.blob&.filename&.to_s), url: default_audio_url(audio), id: audio&.id, filename: audio&.blob&.filename&.to_s, created_at: audio&.created_at, current: is_audio_current?(audio) } }
  end

  def is_audio_current?(audio)
    url = default_audio_url(audio)
    url == audio_url
  end

  def remove_audio_files_before_may_2024
    date = Date.new(2024, 5, 1)
    removed_count = 0
    audio_files.each do |audio|
      if audio.created_at < date
        audio.purge
        removed_count += 1
      end
    end
  end

  def self.remove_old_audio
    Image.find_each do |image|
      image.remove_audio_files_before_may_2024
    end
  end

  def find_or_create_audio_file_for_voice(voice = "alloy", lang = "en")
    if lang == "en"
      filename = "#{label_for_filename}_#{voice}.aac"
    else
      filename = "#{label_for_filename}_#{voice}_#{lang}.aac"
    end

    audio_file = ActiveStorage::Attachment.joins(:blob)
      .where(record: self, name: :audio_files, active_storage_blobs: { filename: filename })
      .first

    if audio_file.present?
      audio_file
    else
      create_audio_from_text(label, voice, lang)
    end
  end

  def translate_to(language)
    current_language = language_from_filename(audio_url)
    translation = OpenAiClient.new(open_ai_opts).translate_text(label, current_language, language)
    puts "Translation: #{translation}"
    lang_settings = language_settings || {}
    lang_settings[language] = { label: translation, display_label: translation }
    self.language_settings = lang_settings
    translation
  end

  def label_for_filename
    label.parameterize
  end

  def find_audio_for_voice(voice = "alloy", lang = "en")
    if lang == "en"
      filename = "#{label_for_filename}_#{voice}.aac"
    else
      filename = "#{label_for_filename}_#{voice}_#{lang}.aac"
    end
    audio_file = ActiveStorage::Attachment.joins(:blob)
      .where(name: :audio_files, active_storage_blobs: { filename: filename })
      .last

    unless audio_file
      Rails.logger.debug "Audio file not found: #{filename} - creating new audio file for #{label} - #{voice} - #{lang}"
      audio_file = find_or_create_audio_file_for_voice(voice, lang)
      self.audio_url = default_audio_url(audio_file)
    end

    audio_file
  end

  def existing_voices
    # Ex: filename = scared_nova_22.aac
    audio_files.map { |audio| voice_from_filename(audio.blob.filename.to_s) }.uniq.compact
  end

  def existing_audio_files
    audio_files.map { |audio| audio.blob.filename.to_s }
  end

  def find_custom_audio_file
    # audio_file = ActiveStorage::Attachment.joins(:blob)
    #   .where(record: self, name: :audio_files, active_storage_blobs: { "filename ILIKE ?" => "%custom%" })
    #   .first
    custom_file = audio_files.find { |audio| audio.blob.filename.to_s.include?("custom") }
    custom_file
  end

  def rename_audio_files
    audio_files.each do |audio|
      voice = voice_from_filename(audio.blob.filename.to_s)
      unless Image.voices.include?(voice)
        Rails.logger.debug "Invalid voice: #{voice} - #{audio.blob.filename}"
        next
      end
      new_filename = "#{label_for_filename}_#{voice}.aac"
      audio.blob.update!(filename: new_filename)
    end
  end

  def destroy_audio_files_without_voices
    audio_files.each do |audio|
      voice = voice_from_filename(audio.blob.filename.to_s)
      unless Image.voices.include?(voice)
        Rails.logger.debug "Destroying audio file without voice: #{voice} - #{audio.blob.filename}"
        audio.purge
      end
    end
  end

  def self.rename_audio_files(scope = nil, limit = 2000)
    count = 0
    scope ||= Image
    scope.find_each do |image|
      image.destroy_audio_files_without_voices
      image.reload
      image.rename_audio_files

      count += 1
      if count >= limit
        puts "Limit reached: #{limit}"
        break
      end
    end
  end

  def voice_from_filename(filename)
    # Ex: scared_nova.aac
    filename.split("_")[1].split(".")[0]
  end

  def label_from_filename(filename)
    filename.split("_")[0]
  end

  def label_voice_from_filename(filename)
    filename.split("_")[0..1].join("_")
  end

  def language_from_filename(filename)
    file_language = filename.split("_")[2]
    if file_language.blank?
      file_language = "en"
    else
      file_language = file_language.split(".")[0]
      unless Image.languages.include?(file_language)
        Rails.logger.debug "Invalid language: #{file_language} - #{filename}"
        file_language = "en"
      end
    end
    file_language
  end

  def self.voices
    ["alloy", "onyx", "shimmer", "nova", "fable", "ash", "coral", "sage"]
  end

  def self.languages
    ["en", "es", "fr", "de", "it", "ja", "ko", "nl", "pl", "pt", "ru", "zh"]
  end

  def core_words
    ["yes", "no", "more", "stop", "go", "help", "please", "thank you", "sorry", "i want", "i feel", "bathroom", "thirsty", "hungry", "tired", "hurt", "happy", "sad", "play", "all done"]
  end

  def action_words
    # Should not repeat any core words
    ["to drink", "to go", "to eat", "to sleep", "to play", "to work", "to read", "to write", "to draw", "to paint", "to sing", "to dance", "to run", "to walk", "to jump", "to sit", "to stand", "to talk", "to listen", "to watch", "to look", "to see", "to hear", "to smell", "to taste", "to touch", "to feel", "to think", "to remember", "to forget", "to learn", "to teach", "to help", "to hurt", "to love", "to hate", "to like", "to dislike", "to want", "to need", "to wish", "to hope", "to dream", "to believe", "to know", "to understand", "to remember", "to forget", "to forgive", "to apologize", "to thank", "to welcome", "to say", "to ask", "to answer", "to tell", "to show", "to give", "to take", "to send", "to receive", "to buy", "to sell", "to pay", "to cost", "to save", "to spend", "to earn", "to lose", "to win", "to find", "to search", "to discover", "to create", "to destroy", "to build", "to break", "to fix", "to repair", "to open", "to close", "to lock", "to unlock", "to start", "to stop", "to finish", "to continue", "to repeat", "to change", "to improve", "to grow", "to shrink", "to expand", "to contract", "to move", "to stay", "to return", "to leave", "to arrive", "to depart", "to enter", "to exit", "to follow", "to lead", "to guide", "to direct", "to drive", "to ride", "to fly", "to swim", "to sail", "to travel", "to visit", "to explore", "to discover", "to learn", "to teach", "to study", "to practice", "to play", "to win", "to lose", "to compete", "to challenge", "to fight", "to argue", "to discuss"]
  end

  # PLACEHOLDERS FOR FUTURE USE
  def self.speeds
    [1, 1.25, 1.5, 1.75, 2]
  end

  def self.pitches
    [1, 1.25, 1.5, 1.75, 2]
  end

  def self.rates
    [1, 1.25, 1.5, 1.75, 2]
  end

  def self.volumes
    [1, 1.25, 1.5, 1.75, 2]
  end

  def missing_voices
    voices = Image.voices
    missing = voices - existing_voices
    missing
  end

  def self.create_sample_audio_for_voices(language = "en")
    audio_files = []
    voices.each do |voice|
      audio_image = Image.find_by(label: "This is the voice #{voice}", private: true, image_type: "SampleVoice", language: language)
      if audio_image
        Rails.logger.debug "Sample voice already exists: #{audio_image.id}"
        audio_files << audio_image.audio_files
      else
        audio_image = Image.create!(label: "This is the voice #{voice}", private: true, image_type: "SampleVoice")
        audio_image.create_audio_from_text("This is the voice #{voice}", voice, language)
        audio_files << audio_image.audio_files
      end
    end
    Rails.logger.debug "Sample voices created: #{audio_files}"
    audio_files
  end

  def self.sample_audio_files
    arry = []
    Image.where(private: true, image_type: "SampleVoice").map do |image|
      file = image.audio_files.last
      label = image.label
      arry << { id: image.id, label: label, file: file, url: file&.url }
    end
    arry
  end

  def self.find_sample_audio_for_voice(voice)
    Image.find_by(label: "This is the voice #{voice}").audio_files&.last
  end

  def generate_matching_symbol(limit = 1)
    # return if open_symbol_status == "skipped"
    query = label&.downcase
    response = OpenSymbol.generate_symbol(query)

    if response
      symbols = JSON.parse(response)
      symbols_count = symbols.count

      count = 0
      skipped_count = 0

      begin
        symbols.each do |symbol|
          existing_symbol = OpenSymbol.find_by(original_os_id: symbol["id"])
          if existing_symbol || OpenSymbol::IMAGE_EXTENSIONS.exclude?(symbol["extension"])
            Rails.logger.debug "Symbol already exists: #{existing_symbol&.id} Or not an image: #{symbol["extension"]}"
            new_symbol = existing_symbol
          else
            break if count >= limit
            new_symbol =
              OpenSymbol.create!(
                name: symbol["name"],
                image_url: symbol["image_url"],
                label: query,
                search_string: symbol["search_string"],
                symbol_key: symbol["symbol_key"],
                locale: symbol["locale"],
                license_url: symbol["license_url"],
                license: symbol["license"],
                original_os_id: symbol["id"],
                repo_key: symbol["repo_key"],
                unsafe_result: symbol["unsafe_result"],
                protected_symbol: symbol["protected_symbol"],
                use_score: symbol["use_score"],
                relevance: symbol["relevance"],
                extension: symbol["extension"],
                enabled: symbol["enabled"],
              )
          end
          symbol_name = new_symbol.name.parameterize if new_symbol
          if new_symbol && should_create_symbol_image?(new_symbol)
            count += 1

            downloaded_image = new_symbol.get_downloaded_image
            processed = nil
            svg_url = nil
            if new_symbol.svg?
              svg_url = new_symbol.image_url
              processed = false
              Rails.logger.debug "Disabling SVG processing for now"
            else
              processed = downloaded_image
            end

            ext = new_symbol.svg? ? "png" : new_symbol.extension
            new_image_doc = self.docs.create!(processed: symbol_name, raw: new_symbol.search_string, source_type: "OpenSymbol", original_image_url: svg_url) if processed
            new_image_doc.image.attach(io: processed, filename: "#{symbol_name}-symbol-#{new_symbol.id}.#{ext}") if processed
          else
            skipped_count += 1
          end
          total = count + skipped_count
          Rails.logger.debug "Label: #{label} - Symbol: #{symbol_name} - Total: #{total} - Count: #{count} - Skipped: #{skipped_count}"
          if total >= symbols_count
            self.update!(open_symbol_status: "skipped")
            break
          end
        end
        symbols
      rescue => e
        Rails.logger.debug "Error creating symbols: #{e.message}\n\n#{e.backtrace.join("\n")}"
        skipped_count += 1
      end
    end
  end

  def self.create_symbols_for_missing_images(limit = 50, sym_limit = 3)
    count = 0
    images_without_docs = Image.public_img.active.non_menu_images.without_docs
    Rails.logger.debug "Images without docs: #{images_without_docs.to_a.count}"
    sleep 3
    images_without_docs.each do |image|
      Rails.logger.debug "Creating symbol image for #{image.label} - sym_limit: #{sym_limit} - count: #{count}"
      image.generate_matching_symbol(sym_limit)
      count += 1
      break if count >= limit
    end
  end

  def should_create_symbol_image?(new_symbol)
    return false if new_symbol.blank?
    symbol_name = new_symbol.name.parameterize
    return false if symbol_name.blank?
    symbol_name_like_label?(symbol_name) && !doc_text_matches(symbol_name)
  end

  def symbol_name_like_label?(symbol_name)
    return false if symbol_name.blank?
    result = false
    label.split(" ").each do |label_word|
      result = symbol_name.split("-").any? { |word| label_word.downcase.include?(word) }
      break if result
    end
    result
  end

  def doc_text_matches(symbol_name)
    return false if symbol_name.blank?
    docs.unscoped.any? { |doc| doc.processed === symbol_name }
  end

  def label_and_user_id
    "#{label_for_filename}_#{user_id}"
  end

  def self.destroy_duplicate_images(dry_run: true, limit: 100, labels: [], user_ids: [User::DEFAULT_ADMIN_ID, nil])
    total_images_destroyed = 0
    total_docs_saved = 0
    ActiveRecord::Base.logger.silence do

      # Count the labels and group them
      if labels.any?
        @label_counts = Image.non_menu_images.where(user_id: user_ids, label: labels).group(:label).count
      else
        @label_counts = Image.non_menu_images.where(user_id: user_ids).group(:label).count
      end

      # Filter for labels with duplicates (count > 1)
      @duplicate_labels = @label_counts.select { |_label, count| count > 1 }

      # Log the number of duplicate labels and the total number of images in those labels
      Rails.logger.debug "Found #{@duplicate_labels.count} labels with duplicates."
      Rails.logger.debug "Total images with duplicate labels: #{@duplicate_labels.values.sum}"
      puts "Found #{@duplicate_labels} labels with duplicates.\n Do you want to continue? (y/n)"
      response = gets.chomp
      return unless response == "y"
      @duplicate_labels.each do |label, image_count|
        Rails.logger.debug "Checking for duplicates for #{label} - #{image_count} images"
        images = Image.where(user_id: user_ids, label: label).order(created_at: :desc)
        # Skip the first image (which we want to keep) and destroy the rest
        # images.drop(1).each(&:destroy)
        puts "\nDuplicate images for #{label}: #{images.count}" if images.count > 1
        keep = images.select { |image| image.user_id != nil }.first
        keep ||= images.first
        keeping_docs = keep.docs
        puts "Urls: #{keeping_docs.pluck(:original_image_url)}" if keeping_docs.any?
        kept_urls = keeping_docs.pluck(:original_image_url).compact

        keep.save! unless dry_run
        images_to_run = images.excluding(keep)
        puts "Images: #{images.count} - Images to run: #{images_to_run.count}"
        images_to_run.each do |image|
          destroying_docs = image.docs

          Rails.logger.debug "Destroying duplicate image: id: #{image.id} - label: #{image.label} - created_at: #{image.created_at} - docs: #{destroying_docs.count}"
          destroying_docs.each do |doc|
            if kept_urls.include?(doc.original_image_url)
              puts "Skipping doc: #{doc.id} - #{doc.original_image_url}"
              next
            end
            doc.update!(documentable_id: keep.id) unless dry_run
            # puts "Reassigning doc #{doc.id} to image #{keep.id} - #{dry_run ? "DRY RUN" : "FOR REAL LIFE"}"
            total_docs_saved += 1
          end

          updating_board_images = BoardImage.where(image_id: image.id)
          updating_board_images.each do |bi|
            bi.update!(image_id: keep.id) unless dry_run
          end

          next_words = image.next_words
          if next_words.any?
            # puts "Next words: #{next_words}"
            keep.next_words = (keep.next_words + next_words).uniq
            keep.save! unless dry_run
          end

          total_images_destroyed += 1

          # puts "Image docs: #{image.docs.count} - Keep docs: #{keep.docs.count}"  # Debug output
          # This reload is IMPORTANT! Otherwise, the keep docs WILL be destroyed & removed from S3!
          image.reload
          # puts "AFTER RELOAD - Image docs: #{image.docs.count} - Keep docs: #{keep.docs.count}"  # Debug output
          puts "dry_run: #{dry_run} - Destroying duplicate image: id: #{image.id} - label: #{image.label} - created_at: #{image.created_at}"
          image.destroy! unless dry_run
          if total_images_destroyed >= limit
            puts "in Limit reached: #{limit}"
            break
          end
        end

        keep.reload
        keep.update_all_boards_image_belongs_to(keep.src_url) unless dry_run
        puts "Total images destroyed: #{total_images_destroyed} - Total docs saved: #{total_docs_saved}\n"

        if total_images_destroyed >= limit
          puts "Limit reached: #{limit}"
          break
        end
      end
    end
    puts "\nTotal images destroyed: #{total_images_destroyed} - Total docs saved: #{total_docs_saved}\n"
    nil
  end

  def self.with_multi_word_labels
    Image.public_img.non_sample_voices.non_menu_images.select { |image| image.label.split(" ").count > 1 }
  end

  def doc_exists_for_user?(user)
    docs.where(user_id: user.id).first
  end

  def label_param
    label&.gsub(" ", "+")
  end

  def set_label
    item_name = label
    item_name.downcase!
    item_name.strip!
    # item_name.gsub!(/[^0-9a-zA-Z!? ]/, "")
    if item_name.blank?
      item_name = "image #{id || "new"}"
    end
    self.label = item_name
  end

  def display_image(viewing_user = nil)
    display_doc(viewing_user)&.image
  end

  def display_image_url(viewing_user = nil)
    doc = display_doc(viewing_user)
    doc ? doc.display_url : nil
  end

  def default_audio_url(audio_file = nil)
    audio_file ||= audio_files.first
    audio_blob = audio_file&.blob

    # first_audio_file = audio_files_attachments.first&.blob
    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      url = "#{ENV["CDN_HOST"]}/#{audio_blob.key}" if audio_blob
    else
      url = audio_file&.url
    end
    url
  end

  def save_audio_file_to_s3!(voice = "alloy", lang = "en")
    create_audio_from_text(label, voice, lang)
    voices_needed = missing_voices || []
    voices_needed = voices_needed - [voice]
  end

  def content_type
    display_doc&.image_blob&.content_type
  end

  def width
    display_doc&.image_blob&.metadata&.dig("width")
  end

  def height
    display_doc&.image_blob&.metadata&.dig("height")
  end

  def display_doc(viewing_user = nil)
    viewing_user ||= self.user
    if viewing_user
      # docs = self.docs.where(user_id: [viewing_user.id, nil, User::DEFAULT_ADMIN_ID])
      user_docs = viewing_user.user_docs.includes(:doc).where(image_id: id)
      docs = user_docs.order(:updated_at).map(&:doc)
      return docs.last if docs.any?
      # if viewing_user.id == self.user_id
      #   return nil
      # end

      docs = self.docs.where(user_id: viewing_user.id)
      return docs.current.first if docs.current.any?
      return docs.first if docs.any?
    end
    base_doc = self.docs.includes(image_attachment: :blob).first
    base_doc
  end

  def display_label
    label&.titleize
  end

  def prompt_to_send
    return temp_prompt if temp_prompt.present?
    image_prompt.blank? ? "#{prompt_for_label} #{label}" : image_prompt
  end

  def prompt_for_label
    "Generate an image of"
  end

  def start_generate_audio_job(voice = "alloy", start_time = 0)
    SaveAudioJob.perform_in(start_time.minutes, [id], voice)
  end

  def self.start_generate_audio_job(ids, voice = "alloy")
    SaveAudioJob.perform_async(ids, voice)
  end

  def self.create_audio_files(start_at = 1, batch_size = 10)
    last_id = 0
    end_at = start_at + batch_size
    Image.find_in_batches(start: start_at, finish: end_at, batch_size: batch_size).with_index do |group, batch|
      Rails.logger.debug "Processing group ##{batch} -- #{group.first.id} - #{group.last.id}"
      # group.each(&:save_audio_file_to_s3!)
      Image.start_generate_audio_job(group.pluck(:id))
      last_id = group.last.id
    end
    last_id + 1
  end

  def start_generate_image_job(start_time = 0, user_id_to_set = nil, image_prompt_to_set = nil, board_id = nil)
    user_id_to_set ||= user_id
    Rails.logger.debug "start_generate_image_job: #{label} - #{user_id_to_set} - #{image_prompt_to_set}"
    run_in = Time.now + start_time * 30 # 30 seconds per image set of 3

    GenerateImageJob.perform_in(run_in, id, user_id_to_set, image_prompt_to_set, board_id)
  end

  def self.run_generate_image_job_for(images)
    start_time = 0
    images.each_slice(3) do |images_slice|
      images_slice.each do |image|
        image.start_generate_image_job(start_time)
      end
      start_time += 1
    end
  end

  def open_ai_opts
    prompt = prompt_to_send
    { prompt: prompt }
  end

  def speak_name
    label
  end

  def prompt_addition
    if image_type == "menu"
      image_prompt.include?(Menu::PROMPT_ADDITION) ? "" : Menu::PROMPT_ADDITION
    else
      # image_prompt.include?(PROMPT_ADDITION) ? "" : PROMPT_ADDITION
      ""
    end
  end

  def api_view(viewing_user = nil)
    @default_audio_url = default_audio_url
    user_board_imgs = user_board_images(viewing_user)
    any_board_imgs = Board.where(image_parent_id: id).map(&:board_images).flatten
    {
      id: id,
      image_type: image_type,
      label: label,
      user_id: user_id,
      obf_id: obf_id,
      user_board_images: user_board_imgs.map { |board_image| { id: board_image.id, board_id: board_image.board_id, name: board_image.board.name } },
      # predictive_board_id: predictive_board_id,
      any_board_imgs: any_board_imgs.map { |board_image| { id: board_image.id, board_id: board_image.board_id, name: board_image.board.name } },
      matching_viewer_boards: matching_viewer_boards(viewing_user).map { |board| { id: board.id, name: board.name } },
      image_prompt: image_prompt,
      next_words: next_words,
      bg_color: bg_class,
      text_color: text_color,
      src: display_image_url(viewing_user) || src_url,
      audio_url: @default_audio_url,
      audio: @default_audio_url,
      status: status,
      error: error,
      open_symbol_status: open_symbol_status,
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  def user_boards(current_user)
    return [] unless current_user
    # boards.user_made_with_scenarios_and_menus.where(user_id: current_user.id)
    # Board.joins(:board_images).where(board_images: { image_id: id }).user_made_with_scenarios_and_menus.where(user_id: current_user.id)
    # current_user.boards.includes(:board_images).where(board_images: { image_id: id }).order(name: :asc)
    current_user.boards.includes(board_images: :board).distinct.order(name: :asc)
  end

  def user_board_images(current_user)
    return [] unless current_user
    board_images.includes(:board).where(boards: { user_id: current_user.id }).order(created_at: :desc)
  end

  def update_src_url
    doc = display_doc(user)
    if doc && doc.display_url
      self.src_url = doc.display_url
    end
  end

  def matching_viewer_images(viewing_user = nil)
    imgs = Image.where(label: label, user_id: [viewing_user&.id]).where.not(id: id)
    imgs = imgs.where.not(status: "marked_for_deletion")
    imgs.order(created_at: :desc)
  end

  def matching_viewer_boards(viewing_user = nil)
    viewing_user ||= user
    if viewing_user
      viewing_user.boards.where("lower(name) = ?", label.downcase).order(name: :asc)
      # Board.where(name: label, user_id: viewing_user.id).order(created_at: :desc)
    else
      Board.where("lower(name) = ?", label.downcase).where(name: label, user_id: User::DEFAULT_ADMIN_ID, predefined: true).order(name: :asc)
    end
  end

  def dynamic?
    image_type == "dynamic"
  end

  def describe_image(doc_url)
    response = OpenAiClient.new(open_ai_opts).describe_image(doc_url)
    puts "Response: #{response}"
    response_content = response.dig("choices", 0, "message", "content").strip
    puts "Response content: #{response_content}"
    self.image_prompt = response_content
    self.save!
    response_content

    # parsed_response = response_content ? JSON.parse(response_content) : nil
    # puts "Parsed response: #{parsed_response}"
    # if parsed_response
    #   parsed_response["output"]["image"]
    # else
    #   nil
    # end
  end

  def predictive_board_image_for_user(viewing_user = nil)
    return nil unless viewing_user
    viewing_user.board_images.where.not(predictive_board_id: nil).where(image_id: id).first
  end

  def with_display_doc(current_user = nil, board = nil, board_image = nil)
    @current_user = current_user
    @predictive_board = predictive_board
    @board_image = board_image
    @board = board
    @board_images = user_board_images(@current_user)
    if @board_image
      doc_img_url = @board_image.display_image_url
    else
      current_doc = display_doc(@current_user)
      current_doc_id = current_doc.id if current_doc
      doc_img_url = current_doc&.display_url
    end
    image_docs = docs.with_attached_image.for_user(@current_user).order(created_at: :desc)
    # user_image_boards = user_boards(@current_user)
    if @current_user.admin?
      user_image_boards = @current_user&.boards&.includes(:board_images).where(predefined: false).distinct.order(name: :asc).limit(30)
    else
      user_image_boards = @current_user&.boards&.includes(:board_images).distinct.order(name: :asc)
    end
    @default_audio_url = default_audio_url
    # is_owner = @current_user && user_id == @current_user&.id
    is_admin_image = [User::DEFAULT_ADMIN_ID, nil].include?(user_id)
    @matching_boards = matching_viewer_boards(@current_user)

    @predictive_board = @board_image&.predictive_board if @board_image

    all_boards = Board.for_user(@current_user).alphabetical

    img_is_dynamic = dynamic?
    img_is_predictive = predictive?
    is_owner = @current_user && user_id == @current_user&.id
    @category_boards = @board_image&.category_boards(@current_user) || @matching_boards || []
    is_category = @category_boards.any?
    @board_settings = @board&.settings || {}

    {
      id: id,
      image_type: image_type,
      label: label,
      image_prompt: image_prompt,
      display_doc: doc_img_url,
      data: data,
      obf_id: obf_id,
      src: doc_img_url,
      src_url: @board_image&.display_image_url,
      predictive_board_board_type: @predictive_board&.board_type,
      audio: @default_audio_url,
      audio_url: @default_audio_url,
      audio_files: audio_files_for_api,
      custom_audio_files: custom_audio_files_for_api,
      language: language,
      language_settings: language_settings,
      status: status,
      error: error,
      text_color: text_color,
      freeze_parent_board: @board_settings["freeze_parent_board"],
      predictive_board_id: @board_image&.predictive_board_id,
      board_images: @board_images.map { |board_image| board_image.index_view(@current_user) },
      dynamic: img_is_dynamic,
      dynamic_board: predictive_board,
      is_predictive: img_is_predictive,
      is_owner: is_owner,
      is_admin_image: is_admin_image,
      is_category: is_category,
      category_boards: @category_boards.map { |board| board.api_view(@current_user) },
      bg_color: bg_color,
      bg_class: bg_class,
      open_symbol_status: open_symbol_status,
      created_at: created_at,
      updated_at: updated_at,
      private: self.private,
      user_id: self.user_id,
      next_words: next_words,
      no_next: no_next,
      part_of_speech: part_of_speech,
      can_edit: (current_user && user_id == current_user.id) || current_user&.admin?,
      user_boards: user_image_boards.map { |board| board.user_api_view(@current_user) },
      all_boards: all_boards.map { |board| board.user_api_view(@current_user) },
      # remaining_boards: @board_image&.remaining_user_boards || user_image_boards.map { |board| board.api_view(@current_user) },
      matching_viewer_images: matching_viewer_images(@current_user).map { |image| { id: image.id, label: image.label, src: image.display_image_url(@current_user) || image.src_url, created_at: image.created_at.strftime("%b %d, %Y"), user_id: image.user_id } },
      matching_viewer_boards: @matching_boards.map { |board|
        { id: board.id, name: board.name, voice: board.voice, user_id: board.user_id, board_type: board.board_type, display_image_url: board.display_image_url || board.image_parent&.src_url, created_at: board.created_at.strftime("%b %d, %Y") }
      },
      docs: image_docs.map do |doc|
        {
          id: doc.id,
          label: label,
          user_id: doc.user_id,
          src: doc.display_url,
          display_url: doc.display_url,
          raw: doc.raw,
          is_current: doc.id == current_doc_id,
          can_edit: (current_user && doc.user_id == current_user.id) || current_user&.admin?,
          original_image_url: doc.original_image_url,
          processed: doc.processed,
          data: doc.data,
          created_at: doc.created_at,
          updated_at: doc.updated_at,
          license: doc.license,
        }
      end,
    }
  end

  def self.searchable_menu_items_for(user = nil)
    if user
      # Image.menu_images.or(Image.where(user_id: user.id)).distinct
      Image.menu_images.where(user_id: user.id).distinct
    else
      Image.menu_images.public_img.distinct
    end
  end

  # def category_board_images
  #   category_board_images = category_boards.map(&:images).flatten
  #   category_board_images = category_board_images.select { |image| image.id != id }
  # end

  # def board_images_for_user(viewing_user)
  #   category_board_images
  # end

  def self.searchable_images_for(user, only_user_images = false)
    if !user
      return Image.with_artifacts.non_sample_voices.public_img.non_menu_images.distinct
    end
    if only_user_images
      Image.with_artifacts.non_sample_voices.where(user_id: user.id).distinct
    else
      Image.with_artifacts.non_sample_voices.public_img.or(Image.with_artifacts.where(user_id: user.id)).or(Image.where(user_id: user.id)).distinct
    end
  end

  def categorize!
    return if menu? || Rails.env.test?
    response = OpenAiClient.new(open_ai_opts).categorize_word(label)
    response_content = response[:content]&.downcase
    parsed_response = response_content ? JSON.parse(response_content) : nil

    part_of_speech = parsed_response&.with_indifferent_access["part_of_speech"] || parsed_response&.with_indifferent_access["partofspeech"] if parsed_response
    if part_of_speech && Image.valid_parts_of_speech.include?(part_of_speech)
      update!(part_of_speech: part_of_speech)
    end
  end

  def self.create_image_from_google_search(img_url, label, title, snippet, file_format, user_id = User::DEFAULT_ADMIN_ID)
    return if Rails.env.test?
    label = label.downcase

    existing_image = Image.public_img.find_by(label: label)
    image = nil
    if existing_image
      image = existing_image
    else
      image = Image.create!(label: label, user_id: user_id, status: "processing", image_prompt: "#{title} #{snippet}", image_type: "GoogleSearch")
    end
    image.save_from_url(img_url, title, snippet, user_id)
    image
  end

  def clone_with_current_display_doc(cloned_user_id, new_name, make_dynamic = false, word_list = [])
    Rails.logger.debug "Cloning image: #{id} - #{label} - #{cloned_user_id} - #{new_name} - #{make_dynamic} - #{word_list}"
    if new_name.blank?
      new_name = label
    end
    @source = self
    if word_list.blank?
      word_list = @source.next_words
    end

    @cloned_user = User.includes(:board_images).find(cloned_user_id)
    unless @cloned_user
      Rails.logger.debug "User not found: #{cloned_user_id} - defaulting to admin"
      cloned_user_id = User::DEFAULT_ADMIN_ID
      @cloned_user = User.find(cloned_user_id)
      if !@cloned_user
        return
      end
    end
    @display_doc = @source.display_doc(@cloned_user)

    @cloned_image = @source.dup
    @cloned_image.user_id = cloned_user_id
    @cloned_image.next_words = word_list
    @cloned_image.label = new_name
    @cloned_image.image_type = @source.image_type
    @cloned_image.image_prompt = @source.image_prompt
    @cloned_image.part_of_speech = @source.part_of_speech
    @cloned_image.status = @source.status
    @cloned_image.obf_id = nil
    @cloned_image.save
    if @source.user_id != @cloned_user.id
      @old_board_images_for_cloned_user = @cloned_user.board_images.includes(:image).where(image_id: @source.id)
      @old_board_images_for_cloned_user.each do |board_image|
        if board_image.image.user_id === @cloned_user.id
          next
        end
        board_image.update!(image_id: @cloned_image.id)
      end
    end
    @cloned_user.predictive_boards.each do |board|
      board_image = board.board_images.find_by(label: @cloned_image.label)
      if board_image
        board_image.update!(image_id: @cloned_image.id)
      end
    end

    if @display_doc && @display_doc.image.attached?
      original_file = @display_doc.image
      if original_file
        new_doc = @display_doc.dup
        new_doc.documentable = @cloned_image
        new_doc.user_id = cloned_user_id
        new_doc.save
        new_doc.image.attach(io: StringIO.new(original_file.download), filename: "img_#{@cloned_image.label}_#{@cloned_image.id}_doc_#{new_doc.id}.#{new_doc.extension || "png"}", content_type: original_file.content_type) unless original_file.nil?
      end
    end

    if @cloned_image.save
      @cloned_image.create_predictive_board(@cloned_user.id, word_list) if make_dynamic
      @cloned_image
    else
      Rails.logger.debug "Error cloning image: #{@cloned_image}"
    end
  end
end
