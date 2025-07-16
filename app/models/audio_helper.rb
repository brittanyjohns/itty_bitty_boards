module AudioHelper
  def create_audio_from_text(text = nil, voice = "alloy", language = "en")
    text = text || self.label
    new_audio_file = nil
    if Rails.env.test?
      return
    end
    response = OpenAiClient.new(open_ai_opts).create_audio_from_text(text, voice, language)
    if response
      # response.stream_to_file("output.aac")
      # audio_file = File.binwrite("audio.mp3", response)
      File.open("output.aac", "wb") { |f| f.write(response) }
      audio_file = File.open("output.aac")
      new_audio_file = save_audio_file(audio_file, voice, language)
      file_exists = File.exist?("output.aac")
      File.delete("output.aac") if file_exists
    else
      Rails.logger.error "**** ERROR - create_audio_from_text **** \nDid not receive valid response.\n #{response&.inspect}"
    end
    new_audio_file
  end

  def find_audio_for_voice(voice = "alloy", lang = "en")
    Rails.logger.debug "#{self.class} - Finding audio file for voice: #{voice}, language: #{lang}"

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
      Rails.logger.debug "New audio file created: #{audio_file&.blob&.filename&.to_s}"
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

  def save_audio_file(audio_file, voice, language = "en")
    Rails.logger.info "Saving audio file for image: #{self.id}, voice: #{voice}, language: #{language}"
    if language == "en"
      self.audio_files.attach(io: audio_file, filename: "#{self.label_for_filename}_#{voice}.aac")
    else
      self.audio_files.attach(io: audio_file, filename: "#{self.label_for_filename}_#{voice}_#{language}.aac")
    end

    new_audio_file = self.audio_files.last
    new_audio_file
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

  def voice_from_filename(filename)
    # Ex: scared_nova.aac
    filename.split("_")[1].split(".")[0]
  end

  def default_audio_url(audio_file = nil)
    if self.class.name == "BoardImage"
      Rails.logger.debug "Getting default audio URL for BoardImage: #{self.id} - voice: #{self.voice}, language: #{self.language}"
      audio_file = find_audio_for_voice(self.voice, self.language)
      audio_blob = audio_file&.blob
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
