module AudioHelper
  def create_audio_from_text(text = nil, voice = "alloy", language = "en")
    text = text || self.label
    if voice.blank?
      voice = "alloy"
    end
    if text.blank?
      Rails.logger.error "AudioHelper - No text provided for audio creation. Returning nil."
      return nil
    end
    new_audio_file = nil
    if Rails.env.test?
      Rails.logger.warn "create_audio_from_text: Skipping audio creation in test environment."
      return
    end
    response = OpenAiClient.new(open_ai_opts).create_audio_from_text(text, voice, language)

    random_filename = "#{SecureRandom.hex(10)}.mp3"

    if response
      File.open(random_filename, "wb") do |file|
        file.write(response)
      end
      audio_file = File.open(random_filename, "rb")
      if audio_file.nil?
        Rails.logger.error "Failed to create audio file from response."
        return nil
      end
      new_audio_file = save_audio_file(audio_file, voice, language)
      file_exists = File.exist?(random_filename)
      if file_exists
        File.delete(random_filename)
      end
      self.audio_url = default_audio_url(new_audio_file)
    else
      Rails.logger.error "**** ERROR - create_audio_from_text **** \nDid not receive valid response.\n #{response&.inspect}"
    end
    new_audio_file
  end

  def find_audio_for_voice(voice = "alloy", lang = "en")
    if Rails.env.test?
      Rails.logger.warn "find_audio_for_voice: Skipping audio creation in test environment."
      return
    end
    if voice.blank?
      voice = "alloy"
    end
    if lang == "en"
      filename = "#{label_for_filename}_#{voice}.mp3"
    else
      filename = "#{label_for_filename}_#{voice}_#{lang}.mp3"
    end
    audio_file = ActiveStorage::Attachment.joins(:blob)
      .where(name: :audio_files, active_storage_blobs: { filename: filename })
      .last

    unless audio_file
      audio_file = find_or_create_audio_file_for_voice(voice, lang)
      self.audio_url = default_audio_url(audio_file)
    end

    audio_file
  end

  def existing_voices
    # Ex: filename = scared_nova_22.mp3
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

  def save_audio_file(audio_file, voice, language = "en")
    if language == "en"
      self.audio_files.attach(io: audio_file, filename: "#{self.label_for_filename}_#{voice}.mp3")
    else
      self.audio_files.attach(io: audio_file, filename: "#{self.label_for_filename}_#{voice}_#{language}.mp3")
    end

    new_audio_file = self.audio_files.last
    new_audio_file
  end

  def find_or_create_audio_file_for_voice(voice = "alloy", lang = "en")
    if lang == "en"
      filename = "#{label_for_filename}_#{voice}.mp3"
    else
      filename = "#{label_for_filename}_#{voice}_#{lang}.mp3"
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

  def all_audio_files_for_api
    audio_files.map { |audio| { voice: voice_from_filename(audio&.blob&.filename&.to_s), url: default_audio_url(audio), id: audio&.id, filename: audio&.blob&.filename&.to_s, created_at: audio&.created_at, current: is_audio_current?(audio) } }
  end

  def is_audio_current?(audio)
    url = default_audio_url(audio)
    url == audio_url
  end

  def voice_from_filename(filename)
    # Ex: scared_nova.mp3
    if filename.include?("_")
      if filename.count("_") >= 2
        return filename.split("_")[1..-2].join("_")
      else
        return filename.split("_")[1].split(".")[0]
      end
    end
    nil
  end

  def default_audio_url(audio_file = nil)
    if self.class.name == "BoardImage"
      if audio_file.nil?
        audio_file = find_audio_for_voice(self.voice, self.language)
        audio_file = audio_files.first if audio_file.nil?
      end
      audio_blob = audio_file&.blob if audio_file
      if audio_blob.nil?
        return nil
      end
    else
      audio_file ||= audio_files.first
      audio_blob = audio_file&.blob
    end
    # first_audio_file = audio_files_attachments.first&.blob
    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      url = "#{ENV["CDN_HOST"]}/#{audio_blob.key}" if audio_blob
    else
      url = audio_file&.url
    end
    url
  end
end
