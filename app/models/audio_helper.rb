module AudioHelper
  # Always return [provider, raw_voice]
  def split_voice(voice_value)
    v = voice_value.to_s.strip
    return ["openai", "alloy"] if v.blank?

    if v.include?(":")
      provider, raw = v.split(":", 2)
      [provider, raw]
    else
      # legacy stored as "alloy"
      ["openai", v]
    end
  end

  # Legacy filename (no provider) for OpenAI, provider-prefixed for others
  def filename_for_voice(voice_value, lang = "en", include_provider_for_openai: false)
    provider, raw = split_voice(voice_value)

    token = if provider == "openai" && !include_provider_for_openai
        raw
      else
        "#{provider}_#{raw}"
      end

    base = "#{label_for_filename}_#{token}"
    base = "#{base}_#{lang}" if lang.present? && lang != "en"
    "#{base}.mp3"
  end

  def create_audio_from_text(text = nil, voice = "openai:alloy", language = "en", instructions = "")
    text = text || self.label
    voice = "openai:alloy" if voice.blank?

    if text.blank?
      Rails.logger.error "AudioHelper - No text provided for audio creation. Returning nil."
      return nil
    end
    return if Rails.env.test?

    synth_io = VoiceService.synthesize_speech(
      text: text,
      voice_value: voice,
      language: language,
    )

    unless synth_io
      Rails.logger.error "**** ERROR - create_audio_from_text **** \nNo valid response from VoiceService.synthesize_speech.\n #{synth_io&.inspect}"
      return nil
    end

    unless synth_io.respond_to?(:rewind) && synth_io.respond_to?(:read)
      synth_io = StringIO.new(synth_io)
    end

    save_audio_file(synth_io, voice, language)
  end

  def find_audio_for_voice(voice_value = "openai:alloy", lang = "en")
    return if Rails.env.test?

    voice_value = "openai:alloy" if voice_value.blank?
    provider, _raw = split_voice(voice_value)

    candidates = []

    if provider == "openai"
      # Prefer legacy first to avoid regen
      candidates << filename_for_voice(voice_value, lang, include_provider_for_openai: false) # feel_alloy.mp3
      candidates << filename_for_voice(voice_value, lang, include_provider_for_openai: true)  # feel_openai_alloy.mp3 (if you ever created)
    else
      candidates << filename_for_voice(voice_value, lang, include_provider_for_openai: true)  # feel_polly_Kevin.mp3
    end

    audio_file = candidates.lazy.map { |fn| find_audio_by_filename(fn) }.find(&:present?)

    unless audio_file
      audio_file = find_or_create_audio_file_for_voice(voice_value, lang)
      self.audio_url = default_audio_url(audio_file) if audio_file
    end

    audio_file
  end

  def find_audio_by_filename(filename)
    audio_file = ActiveStorage::Attachment.joins(:blob)
      .where(name: :audio_files, active_storage_blobs: { filename: filename })
      .first
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
    custom_file = audio_files.find { |audio| audio.blob.filename.to_s.include?("custom") }
    custom_file
  end

  def save_audio_file(audio_io, voice_value, language = "en")
    filename = filename_for_voice(voice_value, language)
    self.audio_files.attach(io: audio_io, filename: filename, content_type: "audio/mpeg")
    self.audio_files.last
  end

  def find_or_create_audio_file_for_voice(voice_value, lang)
    voice_value = "openai:alloy" if voice_value.blank?
    lang = "en" if lang.blank?

    provider, _raw = split_voice(voice_value)

    candidates = []
    if provider == "openai"
      candidates << filename_for_voice(voice_value, lang, include_provider_for_openai: false)
      candidates << filename_for_voice(voice_value, lang, include_provider_for_openai: true)
    else
      candidates << filename_for_voice(voice_value, lang, include_provider_for_openai: true)
    end

    existing = candidates.lazy.map { |fn| find_audio_by_filename(fn) }.find(&:present?)
    return existing if existing.present?

    create_audio_from_text(label, voice_value, lang)
  end

  def default_audio_files
    audio_files.select { |audio| audio.blob.filename.to_s.exclude?("custom") }
  end

  def audio_files_for_api(current_url = nil)
    default_audio_files.map { |audio| { voice: voice_from_filename(audio&.blob&.filename&.to_s), url: default_audio_url(audio), id: audio&.id, filename: audio&.blob&.filename&.to_s, created_at: audio&.created_at, current: is_audio_current?(audio, current_url) } }
  end

  def custom_audio_files
    audio_files.select { |audio| audio.blob.filename.to_s.include?("custom") }
  end

  def custom_audio_files_for_api
    custom_audio_files.map { |audio| { voice: voice_from_filename(audio&.blob&.filename&.to_s), url: default_audio_url(audio), id: audio&.id, filename: audio&.blob&.filename&.to_s, created_at: audio&.created_at, current: is_audio_current?(audio) } }
  end

  def all_audio_files_for_api(current_url = nil)
    audio_files.map { |audio| { voice: voice_from_filename(audio&.blob&.filename&.to_s), url: default_audio_url(audio), id: audio&.id, filename: audio&.blob&.filename&.to_s, created_at: audio&.created_at, current: is_audio_current?(audio, current_url) } }
  end

  def is_audio_current?(audio, current_url = nil)
    url = default_audio_url(audio)
    unless url
      return false
    end
    if current_url.nil?
      current = audio_url
    else
      current = current_url
    end
    url == current
  end

  def voice_from_filename(filename)
    return nil if filename.blank?

    # Custom audio: keep your existing behavior
    if filename.include?("custom")
      parts = filename.split("-")
      return nil if parts.length < 3
      return "#{parts[1]}-#{parts[2]}"
    end

    base = File.basename(filename, File.extname(filename)) # remove .mp3
    parts = base.split("_")
    return nil if parts.length < 2

    # Remove trailing language if present (en, en-US, es, es-US, etc.)
    last = parts.last
    if last.match?(/\A[a-z]{2}(-[A-Z]{2})?\z/)
      parts = parts[0...-1]
    end

    # Now parts look like:
    # legacy openai: [label, alloy]
    # new provider:  [label, polly, kevin] or [label, openai, alloy]

    # If provider is explicitly included
    if parts.length >= 3 && %w[openai polly].include?(parts[1])
      provider = parts[1]
      voice = parts[2]
      return voice
    end

    # Legacy: treat as openai voice
    voice = parts[1]
    voice
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
