class VoiceService
  # Canonical list for the API (single source of truth)
  OPENAI_VOICES = [
    # -----------------------
    # OpenAI
    # -----------------------
    {
      value: "openai:alloy",
      label: "Alloy",
      provider: "openai",
      icon: "male",
      description: "Clear, balanced, neutral tone",
      tags: ["adult", "recommended"],
    },
    {
      value: "openai:shimmer",
      label: "Shimmer",
      provider: "openai",
      icon: "female",
      description: "Upbeat, expressive",
      tags: ["adult"],
    },
    {
      value: "openai:onyx",
      label: "Onyx",
      provider: "openai",
      icon: "male",
      description: "Deeper tone, confident",
      tags: ["adult"],
    },
    {
      value: "openai:fable",
      label: "Fable",
      provider: "openai",
      icon: "female",
      description: "Playful, story-friendly",
      tags: ["adult"],
    },
    {
      value: "openai:nova",
      label: "Nova",
      provider: "openai",
      icon: "female",
      description: "Bright, energetic",
      tags: ["adult"],
    },
    {
      value: "openai:echo",
      label: "Echo",
      provider: "openai",
      icon: "female",
      description: "Calm, soft",
      tags: ["adult"],
    },
    {
      value: "openai:ash",
      label: "Ash",
      provider: "openai",
      icon: "male",
      description: "Relaxed, casual tone",
      tags: ["adult"],
    },
    {
      value: "openai:coral",
      label: "Coral",
      provider: "openai",
      icon: "female",
      description: "Warm, friendly",
      tags: ["adult", "recommended"],
    },
    {
      value: "openai:sage",
      label: "Sage",
      provider: "openai",
      icon: "male",
      description: "Thoughtful, steady",
      tags: ["adult"],
    },
    {
      value: "openai:marin",
      label: "Marin",
      provider: "openai",
      icon: "female",
      description: "Natural, clear (newer)",
      tags: ["adult"],
    },
    {
      value: "openai:cedar",
      label: "Cedar",
      provider: "openai",
      icon: "male",
      description: "Natural, grounded (newer)",
      tags: ["adult"],
    },
  ].freeze

  RECOMMENDED = %w[
    Kevin Joanna Matthew Ivy
    Lupe Lucia
  ].freeze

  VOICES = (PollyTts::VOICES + OPENAI_VOICES).freeze

  # The app-wide fallback when nothing else resolves a voice. Referenced rather
  # than restated: it used to be a bare "polly:kevin" literal in four places
  # (here, User#voice_settings, ChildAccount#voice_settings, normalize_voice),
  # which is what made "the default is a child voice" a four-file change.
  DEFAULT_VOICE = "polly:kevin".freeze

  # Which voice a communicator gets when nobody has picked one, keyed on the
  # `age_band` the communicator form already collects
  # (CommunicatorProfile::AGE_BANDS). The product asks how old the communicator
  # is; this is the one place that answer reaches the voice.
  #
  # Kevin is tagged "kid" and described as such, so it is the default only for
  # the youngest bands. Every other band — including an age_band we do not
  # recognize, which is still evidence that someone answered the question —
  # falls to Joanna, an adult-tagged "recommended" neural voice. A voice a user
  # has actually chosen is never touched by this; it only fills an absence.
  #
  # Every band in CommunicatorProfile::AGE_BANDS needs a row here. An unmapped
  # band takes the ADULT fallback below, so adding a band and forgetting this
  # map hands a 3-year-old an adult voice — the exact failure the map exists
  # to prevent.
  DEFAULT_VOICE_BY_AGE_BAND = {
    "under-4" => "polly:kevin",
    "4-6" => "polly:kevin",
    "7-10" => "polly:kevin",
    "11-14" => "polly:joanna",
    "15-18" => "polly:joanna",
    "adult" => "polly:joanna",
  }.freeze

  # Fallback for a band that is present but unrecognized. Deliberately the
  # adult voice: a blank band means "we were never told", but an unknown one
  # means the answer exists and simply is not in our table — defaulting that to
  # a child voice is the failure this map exists to prevent.
  DEFAULT_VOICE_FOR_UNKNOWN_BAND = "polly:joanna".freeze

  # nil/blank band => DEFAULT_VOICE (unchanged behavior for every caller that
  # has no profile to consult).
  def self.default_for_age_band(age_band)
    band = age_band.to_s.strip.downcase
    return DEFAULT_VOICE if band.blank?

    DEFAULT_VOICE_BY_AGE_BAND[band] || DEFAULT_VOICE_FOR_UNKNOWN_BAND
  end

  # --- API-friendly list ---
  def self.get_voice_options
    VOICES.map do |v|
      {
        label: v[:label],
        value: v[:value],
        provider: v[:provider],
        icon: v[:icon],
        description: v[:description],
        tags: v[:tags] || [],
        engine: v[:engine],      # nil for OpenAI
        language: v[:language],  # nil for OpenAI
      }.compact
    end
  end

  # Backward compat (if some client expects just labels)
  def self.get_voice_labels
    VOICES.map { |v| v[:label] }
  end

  def self.get_voice_values
    VOICES.map { |v| v[:value] }
  end

  # Voice `value`s appropriate for synthesizing text in the given language.
  # Polly voices carry an ISO-region `language` tag (e.g. "es-US"); we match on
  # the ISO 639-1 prefix. OpenAI voices have no language tag — the model follows
  # the input text — so they're always included.
  def self.voices_for_language(iso)
    iso = iso.to_s.strip.downcase.split(/[-_]/).first
    iso = "en" if iso.blank?

    VOICES.select do |v|
      v[:language].blank? || v[:language].to_s.downcase.split(/[-_]/).first == iso
    end.map { |v| v[:value] }
  end

  # Support looking up by label OR by value
  def self.get_voice(value_or_label)
    v = VOICES.find { |opt| opt[:value].casecmp(value_or_label.to_s) == 0 }
    return v if v

    VOICES.find { |opt| opt[:label].casecmp(value_or_label.to_s) == 0 }
  end

  # Prefer passing voice_value ("polly:kevin") from the client.
  # Keep voice_label working for older clients.
  def self.synthesize_speech(text:, voice_value: nil, voice_label: nil, language: "en", audio_type: "audio_files")
    opt = if voice_value.present?
        get_voice(voice_value)
      else
        get_voice(voice_label)
      end

    raise ArgumentError, "Invalid voice: #{voice_value || voice_label}" if opt.nil?

    value = opt[:value]
    provider, raw_voice = value.split(":", 2)

    case provider
    when "openai"
      response = OpenAiClient.new({}).create_audio_from_text(text, raw_voice, language)
    when "polly"
      polly = PollyTts.new
      # If you want to use engine metadata:
      engine = opt[:engine] || "neural"
      polly.synthesize_mp3!(text: text, voice_id: raw_voice, engine: engine)
    else
      raise ArgumentError, "Unsupported provider: #{provider}"
    end
  end

  def self.normalize_voice(value_or_label)
    raw = value_or_label.to_s.strip
    return DEFAULT_VOICE if raw.blank?

    # Already canonical?
    return raw if raw.include?(":")

    # Legacy openai voice name only (e.g., "alloy")
    openai_candidate = "openai:#{raw.downcase}"
    return openai_candidate if get_voice(openai_candidate)

    # Maybe a display label (e.g., "Alloy" / "Kevin (Kid)")
    opt = get_voice(raw)
    return opt[:value] if opt

    DEFAULT_VOICE
  end
end
