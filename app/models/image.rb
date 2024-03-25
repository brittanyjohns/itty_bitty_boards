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
#
class Image < ApplicationRecord
  normalizes :label, with: -> label { label.downcase.strip }
  attr_accessor :temp_prompt
  default_scope { includes(:docs) }
  belongs_to :user, optional: true
  has_many :docs, as: :documentable, dependent: :destroy
  has_many :board_images, dependent: :destroy
  has_many :boards, through: :board_images
  has_many_attached :audio_files

  accepts_nested_attributes_for :docs

  PROMPT_ADDITION = " Styled as a simple cartoon illustration."

  include ImageHelper

  # before_save :save_audio_file, if: -> { label_changed? }
  # before_save :save_audio_file_to_s3!, if: :no_audio_saved
  scope :without_attached_audio_files, -> { where.missing(:audio_files_attachments) }

  # scope :with_image_docs_for_user, -> (userId) { joins(:docs).where("docs.documentable_id = images.id AND docs.documentable_type = 'Image' AND docs.user_id = ?", userId) }
  scope :with_image_docs_for_user, -> (userId) { order(created_at: :desc) }
  scope :menu_images, -> { where(image_type: "Menu") }
  scope :non_menu_images, -> { where.not(image_type: "Menu") }
  scope :non_scenarios, -> { where.not(image_type: "OpenaiPrompt") }
  scope :public_img, -> { where(private: [false, nil]) }
  scope :created_in_last_2_hours, -> { where("created_at > ?", 2.hours.ago) }
  scope :skipped, -> { where(open_symbol_status: "skipped") }

  # after_create :start_create_all_audio_job

  def create_image_doc(user_id = nil)
    response = create_image(user_id)
    # self.image_prompt = prompt_to_send
  end

  def should_create_audio_files?
    audio_files.count < Image.voices.count
  end

  def start_create_all_audio_job
    CreateAllAudioJob.perform_async(id)
  end

  def create_voice_audio_files
    Image.voices.each do |voice|
      if !audio_file_exists_for?(voice)
        # blob).where("active_storage_blobs.filename = ?", "#{label.parameterize}_#{voice}_#{id}.aac").blank?
        create_audio_from_text(label, voice)
      else
        puts "Audio file already exists for voice: #{voice}"
      end
    end
  end

  def audio_file_exists_for?(voice)
    audio_files_blobs.where(filename: "#{label}_#{voice}_#{id}.aac").any?
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

  def find_or_create_audio_file_for_voice(voice = "alloy")
    existing = audio_files.joins(:blob).where("active_storage_blobs.filename = ?", "#{label}_#{voice}_#{id}.aac").first
    if existing
      puts "#{label} ==> Audio file already exists for voice: #{voice} - #{existing.filename}"
      existing
    else
      puts "#{label} ==> Creating audio file for voice: #{voice}"
      create_audio_from_text(label, voice)
    end
  end

  def get_audio_for_voice(voice = "alloy")
    puts "GETTING AUDIO FOR VOICE: #{voice}"
    # file = audio_files.find_by(filename: "#{label}_#{voice}_#{id}.aac")
    file = audio_files.joins(:blob).where("active_storage_blobs.filename = ?", "#{label}_#{voice}_#{id}.aac").first
    if file
      file
    else
      # create_audio_from_text(label, voice)
      # start_generate_audio_job(voice)
      begin
        # save_audio_file_to_s3!(voice)
      rescue => e
        puts "Error getting audio for voice: #{e.message}\n\n#{e.backtrace.join("\n")}"
      end
      # file = audio_files.last
      puts "\n\n Created audio file: #{file.inspect}\n\n"
    end
    file
  end

  def get_voice_for_board(board)
    return unless board
    voice = board_images.find_by(board_id: board.id).voice || Image.voices.sample
    get_audio_for_voice(voice)
  end

  def existing_voices
    # scared_nova_22.aac
    audio_files.map { |audio| audio.filename.to_s.split("_").second }
  end

  def self.voices
    ['alloy', 'echo', 'fable', 'onyx', 'nova', 'shimmer']
  end

  def self.languages
    ['en', 'es', 'fr', 'de', 'it', 'ja', 'ko', 'nl', 'pl', 'pt', 'ru', 'zh']
  end

  def missing_voices
    voices = Image.voices
    missing = voices - existing_voices
    missing
  end

  def self.create_sample_audio_for_voices
    voices.each do |voice|
      Image.find_or_create_by!(label: "This is the voice #{voice}", private: true).create_audio_from_text("This is the voice #{voice}", voice)
    end
  end

  def self.sample_audio_files
    audio_files = []
    voices.each do |voice|
      audio_files << Image.find_by(label: "This is the voice #{voice}").audio_files
    end
    audio_files
  end

  def self.find_sample_audio_for_voice(voice)
    Image.find_by(label: "This is the voice #{voice}").audio_files&.last
  end

  def generate_matching_symbol(limit = 1)
    return if open_symbol_status == "skipped"
    query = label&.downcase
    response = OpenSymbol.generate_symbol(query)

    if response
      symbols = JSON.parse(response)
      symbols_count = symbols.count
      puts "Found symbols...#{symbols_count}"
      puts "Limiting to #{limit} symbols"
      count = 0
      skipped_count = 0
      begin
      symbols.each do |symbol|
        existing_symbol = OpenSymbol.find_by(original_os_id: symbol["id"])
        if existing_symbol || OpenSymbol::IMAGE_EXTENSIONS.exclude?(symbol["extension"])
          puts "Symbol already exists: #{existing_symbol&.id} Or not an image: #{symbol["extension"]}"
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
          enabled: symbol["enabled"]
        )
        end
        symbol_name = new_symbol.name.parameterize if new_symbol
        if new_symbol && should_create_symbol_image?(symbol_name)
          count += 1
          downloaded_image = new_symbol.get_downloaded_image
          new_image_doc = self.docs.create!(processed: symbol_name, raw: new_symbol.search_string, source_type: "OpenSymbol")
          new_image_doc.image.attach(io: downloaded_image, filename: "#{symbol_name}-symbol-#{new_symbol.id}.#{new_symbol.extension}")
        else
          skipped_count += 1
        end
        total = count + skipped_count
        if total >= symbols_count
          puts "Skipped all symbols"
          self.update!(open_symbol_status: "skipped")
          break
        end
      end
      symbols
      rescue => e
        puts "Error creating symbols: #{e.message}\n\n#{e.backtrace.join("\n")}"
      end
    end
  end

  def should_create_symbol_image?(symbol_name)
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

  def self.destroy_duplicate_images
    Image.all.group_by(&:label).each do |label, images|
      puts "label: #{label} - #{images.count}"
      # Skip the first image (which we want to keep) and destroy the rest
      images.drop(1).each(&:destroy)

    end
  end

  def doc_exists_for_user?(user)
    docs.where(user_id: user.id).any?
  end

  def label_param
    label&.gsub(" ", "+")
  end

  def display_image(viewing_user = nil)
    if viewing_user
      img = viewing_user.display_doc_for_image(self)&.image
      if img
        return img if img.attached?
      end
    end
    if docs.current.any? && docs.current.last.image&.attached?
      return docs.current.last.image if docs.current.last.image.attached?
    end
    if docs.any? && docs.last.image&.attached?
      return docs.last.image if docs.last.image.attached?
    end
    nil
  end

  def save_audio_file_to_s3!(voice = "alloy")
    create_audio_from_text(label, voice)
    voices_needed = missing_voices || []
    puts "Voices needed: #{voices_needed}"
    voices_needed = voices_needed - [voice]
    puts "Missing voices: #{missing_voices}"
    # if voices_needed.any?
    #   puts "Starting generate audio job for missing voices: #{voices_needed}"
    #   voices_needed.each do |v|
    #     Image.start_generate_audio_job([id], v)
    #   end
    # end
  end

  def display_doc(viewing_user = nil)
    if viewing_user
      img = viewing_user.display_doc_for_image(self)
      if img
        return img
      end
    end
    if docs.current.any? && docs.current.last.image&.attached?
      return docs.current.last
    end
    if docs.any? && docs.last.image&.attached?
      return docs.last
    end
    nil
  end

  def display_label
    label&.titleize&.truncate(27, separator: ' ')
  end

  def current_doc_for_user(user)
    UserDoc.where(user_id: user.id, doc_id: docs.pluck(:id)).first&.doc
  end

  def prompt_to_send
    return temp_prompt if temp_prompt.present?
    image_prompt.blank? ? "#{prompt_for_label} #{label}" : image_prompt
  end

  def prompt_for_label
    "Generate an image of"
  end

  def start_generate_audio_job(voice = "alloy", start_time = 0)
    # SaveAudioJob.perform_async([id], voice)
    SaveAudioJob.perform_in(start_time.minutes, [id], voice)
  end

  def self.start_generate_audio_job(ids, voice = 'alloy')
    SaveAudioJob.perform_async(ids, voice)
  end

  def self.create_audio_files(start_at=1, batch_size = 10)
    last_id = 0
    end_at = start_at + batch_size
    Image.find_in_batches(start: start_at, finish: end_at, batch_size: batch_size).with_index do |group, batch|
      puts "Processing group ##{batch} -- #{group.first.id} - #{group.last.id}"
      # group.each(&:save_audio_file_to_s3!)
      Image.start_generate_audio_job(group.pluck(:id))
      sleep(3)
      last_id = group.last.id
    end
    last_id + 1
  end

  def start_generate_image_job(start_time = 0, user_id_to_set = nil, image_prompt_to_set = nil)
    user_id_to_set ||= user_id
    puts "start_generate_image_job: #{label} - #{user_id_to_set} - #{image_prompt_to_set}"
    GenerateImageJob.perform_in(start_time.minutes, id, user_id_to_set, image_prompt_to_set)
  end

  def self.run_generate_image_job_for(images)
    start_time = 0
    images.each_slice(5) do |images_slice|
      puts "start_time: #{start_time}"
      puts "images_slice: #{images_slice.map(&:label)}"
      images_slice.each do |image|
        image.start_generate_image_job(start_time)
      end
      start_time += 2
    end
  end

  def open_ai_opts
    prompt = prompt_to_send
    puts "Sending prompt: #{prompt}"
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

  def with_display_doc(current_user = nil)
    {
      id: id,
      label: label,
      image_prompt: image_prompt,
      display_doc: display_image(current_user),
      src: display_image(current_user) ? display_image(current_user).url : "https://via.placeholder.com/300x300.png?text=#{label_param}",
      audio: audio_files.first ? url_for(audio_files.first) : nil
    }
  end

  def self.searchable_menu_items_for(user = nil)
    if user
      Image.menu_images.or(Image.where(user_id: user.id)).distinct
    else
      Image.menu_images.public_img.distinct
    end
  end

  def self.searchable_images_for(user, only_user_images = false)
    if only_user_images
      Image.non_menu_images.or(Image.where(user_id: [user.id, nil])).distinct
    else
      Image.non_menu_images.or(Image.where(user_id: [user.id, nil])).or(Image.public_img.non_menu_images).distinct
    end
  end
end
