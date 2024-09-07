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
#
class Image < ApplicationRecord
  paginates_per 50
  normalizes :label, with: ->label { label.downcase.strip }
  attr_accessor :temp_prompt
  belongs_to :user, optional: true
  has_many :docs, as: :documentable, dependent: :destroy
  has_many :board_images, dependent: :destroy
  has_many :boards, through: :board_images
  has_many_attached :audio_files
  belongs_to :dynamic_board, optional: true

  accepts_nested_attributes_for :docs

  PROMPT_ADDITION = " Styled as a simple cartoon illustration."

  include ImageHelper
  include Rails.application.routes.url_helpers
  include PgSearch::Model
  pg_search_scope :search_by_label, against: :label, using: { tsearch: { prefix: true } }

  def self.rebuild_pg_search_documents
    find_each { |record| record.update_pg_search_document }
  end

  scope :without_attached_audio_files, -> { where.missing(:audio_files_attachments) }

  scope :with_image_docs_for_user, ->(userId) { order(created_at: :desc) }
  scope :menu_images, -> { where(image_type: "Menu") }
  scope :non_menu_images, -> { where.not(image_type: "Menu").or(where(image_type: nil)) }
  scope :non_scenarios, -> { where.not(image_type: "OpenaiPrompt").or(where(image_type: nil)) }
  scope :non_sample_voices, -> { where.not(image_type: "SampleVoice").or(where(image_type: nil)) }
  scope :sample_voices, -> { where(image_type: "SampleVoice") }
  scope :no_image_type, -> { where(image_type: nil) }
  scope :public_img, -> { where(private: false) }
  scope :private_img, -> { where(private: true) }
  scope :created_in_last_2_hours, -> { where("created_at > ?", 2.hours.ago) }
  scope :skipped, -> { where(open_symbol_status: "skipped") }
  scope :active, -> { where(open_symbol_status: "active") }
  scope :without_docs, -> { where.missing(:docs) }
  scope :with_docs, -> { where.associated(:docs) }
  scope :generating, -> { where(status: "generating") }
  scope :with_artifacts, -> { includes({ docs: { image_attachment: :blob } }) }

  scope :with_less_than_3_docs, -> { joins(:docs).group("images.id").having("count(docs.id) < 3") }
  after_create :categorize!, unless: :menu?
  before_save :set_label, :ensure_defaults
  after_save :generate_matching_symbol, if: -> { should_generate_symbol? }
  after_save :run_set_next_words_job, if: -> { should_set_next_words? }

  scope :menu_images_without_docs, -> { menu_images.without_docs }

  def ensure_defaults
    if !image_type
      self.image_type = "Image"
    end
    if image_type == "Menu"
      self.part_of_speech = "noun"
    else
      self.bg_color = background_color_for(part_of_speech)
    end
    if audio_url.blank?
      self.audio_url = default_audio_url
    end
    Rails.logger.debug "Image: #{label} - bg_color: #{bg_color} - part_of_speech: #{part_of_speech} - image_type: #{image_type}"
  end

  def should_generate_symbol?
    return false if image_type == "Menu"
    label_changed? && open_symbol_status == "active"
  end

  def should_set_next_words?
    return false if image_type == "Menu"
    next_words.blank? && no_next == false
  end

  def run_set_next_words_job
    Rails.logger.debug "Starting set next words job for #{label}"
    SetNextWordsJob.perform_async([id])
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
    else
      color = "gray"
    end
    Rails.logger.debug "Background Color: #{color}"
    color
  end

  def bg_class
    bg_color ? "bg-#{bg_color}-400" : "bg-white"
  end

  def create_image_doc(user_id = nil)
    response = create_image(user_id)
    Rails.logger.debug "Response: #{response}"
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

  def start_create_all_audio_job
    CreateAllAudioJob.perform_async(id)
  end

  def create_voice_audio_files
    Image.voices.each do |voice|
      if !audio_file_exists_for?(voice)
        create_audio_from_text(label, voice)
      else
        voice = user_id ? user.voice : "echo"
        create_audio_from_text(label, voice)
      end
    end
  end

  def self.create_single_audio_for_images_missing(limit = 50)
    voice = "echo"
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
    similar_images = Image.public_img.where(label: label).where.not(id: id)
    next_words = similar_images.pluck(:label).uniq
    new_next_words = next_words
    new_next_words = get_next_words(label) unless new_next_words.any?
    Rails.logger.debug "New next words: #{new_next_words}"
    if new_next_words
      self.next_words = new_next_words
      self.save!
    else
      Rails.logger.debug "No next words found for #{label}"
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
      Rails.logger.debug "\n\nStarting set next words job for #{img_ids}\n\n"

      SetNextWordsJob.perform_async(img_ids)
      count += 20
      break if count >= limit
      sleep(1)
    end
  end

  def next_images
    imgs = Image.with_artifacts.where(label: next_words).public_img.order(created_at: :desc).distinct(:label)
    return imgs if imgs.any?
    Board.predictive_default.images
  end

  def next_board
    parent_resource = PredefinedResource.find_or_create_by name: "Next", resource_type: "Board"
    next_board = Board.find_or_create_by!(name: label, user_id: User::DEFAULT_ADMIN_ID, parent: parent_resource)
    puts "Next board: #{next_board.inspect}"
    next_board
  end

  def create_next_board
    next_board_to_use = next_board
    next_board_to_use.add_images(next_images)
    next_board_to_use
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

  def audio_file_exists_for?(voice)
    audio_files_blobs.where(filename: "#{label}_#{voice}.aac").any?
  end

  def menu?
    image_type == "Menu"
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

  def audio_files_for_api
    audio_files.map { |audio| { voice: voice_from_filename(audio&.blob&.filename&.to_s), url: default_audio_url(audio), id: audio&.id, filename: audio&.blob&.filename&.to_s, created_at: audio&.created_at } }
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
    puts "Removed #{removed_count} audio files"
  end

  def self.remove_old_audio
    Image.find_each do |image|
      image.remove_audio_files_before_may_2024
    end
  end

  def find_or_create_audio_file_for_voice(voice = "echo")
    filename = "#{label_for_filename}_#{voice}.aac"

    audio_file = ActiveStorage::Attachment.joins(:blob)
      .where(record: self, name: :audio_files, active_storage_blobs: { filename: filename })
      .first

    if audio_file.present?
      audio_file
    else
      Rails.logger.debug "#{label} ==> Creating audio file for voice: #{voice}"
      create_audio_from_text(label, voice)
    end
  end

  def label_for_filename
    label.parameterize
  end

  def find_audio_for_voice(voice = "echo")
    filename = "#{label_for_filename}_#{voice}.aac"

    audio_file = ActiveStorage::Attachment.joins(:blob)
      .where(record: self, name: :audio_files, active_storage_blobs: { filename: filename })
      .first

    audio_file
  end

  def existing_voices
    # Ex: filename = scared_nova_22.aac
    audio_files.map { |audio| voice_from_filename(audio.blob.filename.to_s) }.uniq.compact
  end

  def existing_audio_files
    audio_files.map { |audio| audio.blob.filename.to_s }
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

  def self.voices
    ["echo", "echo", "fable", "onyx", "nova", "shimmer", "alloy"]
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

  def self.create_sample_audio_for_voices
    audio_files = []
    voices.each do |voice|
      audio_image = Image.find_by(label: "This is the voice #{voice}", private: true, image_type: "SampleVoice")
      if audio_image
        Rails.logger.debug "Sample voice already exists: #{audio_image.id}"
        audio_files << audio_image.audio_files
      else
        audio_image = Image.create!(label: "This is the voice #{voice}", private: true, image_type: "SampleVoice")
        audio_image.create_audio_from_text("This is the voice #{voice}", voice)
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
              # processed = ImageProcessing::MiniMagick
              #   .convert("png")
              #   .resize_to_limit(300, 300)
              #   .call(downloaded_image)
              # Rails.logger.debug "Processed SVG: #{processed}"
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

  def self.destroy_duplicate_images(dry_run: true)
    total_images_destroyed = 0
    total_docs_saved = 0
    puts "RUNNING FOR #{Image.includes(:docs).non_menu_images.count} IMAGES"
    Image.includes(:docs).non_menu_images.group_by(&:label).each do |label, images|
      # Skip the first image (which we want to keep) and destroy the rest
      # images.drop(1).each(&:destroy)
      puts "\nDuplicate images for #{label}: #{images.count}" if images.count > 1
      keep = images.first
      keeping_docs = keep.docs
      images.drop(1).each do |image|
        destroying_docs = image.docs

        Rails.logger.debug "Destroying duplicate image: id: #{image.id} - label: #{image.label} - created_at: #{image.created_at} - docs: #{destroying_docs.count}"
        destroying_docs.each do |doc|
          doc.update!(documentable_id: keep.id) unless dry_run
          puts "Reassigning doc #{doc.id} to image #{keep.id} - #{dry_run ? "DRY RUN" : "FOR REAL LIFE"}"
          total_docs_saved += 1
        end

        next_words = image.next_words
        if next_words.any?
          puts "Next words: #{next_words}"
          keep.next_words = (keep.next_words + next_words).uniq
          keep.save! unless dry_run
        end

        total_images_destroyed += 1

        puts "Image docs: #{image.docs.count} - Keep docs: #{keep.docs.count}"  # Debug output
        # This reload is IMPORTANT! Otherwise, the keep docs WILL be destroyed & removed from S3!
        image.reload
        puts "AFTER RELOAD - Image docs: #{image.docs.count} - Keep docs: #{keep.docs.count}"  # Debug output
        puts "dry_run: #{dry_run} - Destroying duplicate image: id: #{image.id} - label: #{image.label} - created_at: #{image.created_at}"
        image.destroy unless dry_run
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
    if item_name.blank?
      item_name = "image #{id || "new"}"
    end
    item_name.downcase!
    item_name.strip!
    self.label = item_name
  end

  def display_image(viewing_user = nil)
    display_doc(viewing_user)&.image
  end

  def display_image_url(viewing_user = nil)
    doc = display_doc(viewing_user)
    # doc ? doc.display_url : "https://via.placeholder.com/300x300.png?text=#{label_param}"
    doc ? doc.display_url : nil
  end

  def default_audio_url(audio_file = nil)
    audio_file ||= audio_files.first
    audio_blob = audio_file&.blob

    # first_audio_file = audio_files_attachments.first&.blob
    cdn_url = "#{ENV["CDN_HOST"]}/#{audio_blob.key}" if audio_blob
    audio_blob ? cdn_url : nil
  end

  def save_audio_file_to_s3!(voice = "echo")
    create_audio_from_text(label, voice)
    voices_needed = missing_voices || []
    Rails.logger.debug "Voices needed: #{voices_needed}"
    voices_needed = voices_needed - [voice]
    Rails.logger.debug "Missing voices: #{missing_voices}"
  end

  def no_user_or_admin?
    user_id.nil? || User.admin.pluck(:id).include?(user_id)
  end

  def display_doc(viewing_user = nil)
    # Attempt to find a doc for a viewing user
    doc = viewing_user&.display_doc_for_image(id)
    # Return the doc if it exists, else find a userless doc
    doc || userless_doc
  end

  def userless_doc
    ActiveRecord::Base.logger.silence do
      default_admin = User.includes(:user_docs, :docs).admin.first
      doc = default_admin&.display_doc_for_image(id)
      doc = docs.where(user_id: nil).first unless doc
      doc
    end
  end

  def display_label
    label&.titleize&.truncate(27, separator: " ")
  end

  def prompt_to_send
    return temp_prompt if temp_prompt.present?
    image_prompt.blank? ? "#{prompt_for_label} #{label}" : image_prompt
  end

  def prompt_for_label
    "Generate an image of"
  end

  def start_generate_audio_job(voice = "echo", start_time = 0)
    SaveAudioJob.perform_in(start_time.minutes, [id], voice)
  end

  def self.start_generate_audio_job(ids, voice = "echo")
    SaveAudioJob.perform_async(ids, voice)
  end

  def self.create_audio_files(start_at = 1, batch_size = 10)
    last_id = 0
    end_at = start_at + batch_size
    Image.find_in_batches(start: start_at, finish: end_at, batch_size: batch_size).with_index do |group, batch|
      Rails.logger.debug "Processing group ##{batch} -- #{group.first.id} - #{group.last.id}"
      # group.each(&:save_audio_file_to_s3!)
      Image.start_generate_audio_job(group.pluck(:id))
      sleep(3)
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
    if image_type == "Menu"
      image_prompt.include?(Menu::PROMPT_ADDITION) ? "" : Menu::PROMPT_ADDITION
    else
      # image_prompt.include?(PROMPT_ADDITION) ? "" : PROMPT_ADDITION
      ""
    end
  end

  def api_view(viewing_user = nil)
    {
      id: id,
      label: label,
      image_prompt: image_prompt,
      image_type: image_type,
      next_words: next_words,
      bg_color: bg_class,
      text_color: text_color,
      src: display_image_url(viewing_user),
      # src: display_image(viewing_user) ? display_image(viewing_user).url : "https://via.placeholder.com/300x300.png?text=#{label_param}",
      audio: default_audio_url,
      status: status,
      error: error,
      open_symbol_status: open_symbol_status,
      created_at: created_at,
      updated_at: updated_at,
    }
  end

  def remaining_user_boards(current_user)
    return [] unless current_user
    current_user.boards.user_made_with_scenarios - boards
  end

  def user_boards(current_user)
    return [] unless current_user
    boards.where(user_id: current_user.id)
  end

  def board_images_for(current_user)
    return [] unless current_user
    board_images.where(board_id: current_user.boards.pluck(:id))
  end

  def with_display_doc(current_user = nil)
    current_doc = display_doc(current_user)
    current_doc_id = current_doc.id if current_doc
    image_docs = docs.with_attached_image.for_user(current_user).order(created_at: :desc)
    remaining = remaining_user_boards(current_user)
    user_image_boards = user_boards(current_user)
    board_images = board_images_for(current_user)
    {
      id: id,
      label: label,
      image_prompt: image_prompt,
      display_doc: display_image(current_user),
      src: display_image_url(current_user),
      audio: default_audio_url,
      audio_files: audio_files_for_api,
      status: status,
      error: error,
      text_color: text_color,
      bg_color: bg_class,
      open_symbol_status: open_symbol_status,
      created_at: created_at,
      updated_at: updated_at,
      private: self.private,
      user_id: self.user_id,
      next_words: next_words,
      no_next: no_next,
      part_of_speech: part_of_speech,
      board_images: board_images.map { |board_image| { id: board_image.id, board_id: board_image.board_id, image_id: board_image.image_id, label: board_image.label, board_name: board_image.board.name } },
      user_boards: user_image_boards.map { |board| { id: board.id, name: board.name } },
      remaining_boards: remaining.map { |board| { id: board.id, name: board.name } },
      docs: image_docs.map do |doc|
        {
          id: doc.id,
          label: label,
          user_id: doc.user_id,
          src: doc.display_url,
          raw: doc.raw,
          is_current: doc.id == current_doc_id,
          can_edit: (current_user && doc.user_id == current_user.id) || current_user&.admin?,
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

  def self.searchable_images_for(user, only_user_images = false)
    if only_user_images
      Image.with_artifacts.where(user_id: user.id).distinct
    else
      Image.with_artifacts.public_img.non_menu_images.non_scenarios.or(Image.with_artifacts.where(user_id: user.id)).or(Image.where(user_id: user.id)).distinct
    end
  end

  def categorize!
    return if part_of_speech.present? || menu? || Rails.env.test?
    response = OpenAiClient.new(open_ai_opts).categorize_word(label)
    Rails.logger.debug "Response: #{response}"
    parsed_response = response[:content]&.downcase
    if parsed_response
      Rails.logger.debug "Category: #{parsed_response}"
      update!(part_of_speech: parsed_response)
    end
  end

  def self.create_image_from_google_search(img_url, label, title, snippet, file_format, user_id = User::DEFAULT_ADMIN_ID)
    return if Rails.env.test?
    label = label.downcase

    existing_image = Image.public_img.find_by(label: label)
    image = nil
    if existing_image
      Rails.logger.debug "Image already exists: #{label}"
      image = existing_image
    else
      image = Image.create!(label: label, user_id: user_id, status: "processing", image_prompt: "#{title} #{snippet}", image_type: "GoogleSearch")
    end
    image.save_from_google(img_url, title, snippet, user_id)
    # new_img = self.create(label: label, user_id: user_id, status: "processing", source_type: "GoogleSearch", image_prompt: revised_prompt).save
    image
  end

  def clone_with_docs(cloned_user_id, new_name)
    if new_name.blank?
      new_name = label
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
    @docs = @source.docs.for_user(cloned_user)
    @cloned_image = @source.dup
    @cloned_image.user_id = cloned_user_id
    @cloned_image.label = new_name
    @cloned_image.save
    @docs.each do |doc|
      original_file = doc.image
      new_doc = doc.dup
      new_doc.documentable = @cloned_image
      new_doc.save
      new_doc.image.attach(io: StringIO.new(original_file.download), filename: "img_#{@cloned_image.label}_#{@cloned_image.id}_doc_#{new_doc.id}.webp", content_type: original_file.content_type)
    end
    if @cloned_image.save
      @cloned_image
    else
      Rails.logger.debug "Error cloning image: #{@cloned_image}"
    end
  end
end
