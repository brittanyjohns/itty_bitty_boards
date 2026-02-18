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

  # Support looking up by label OR by value
  def self.get_voice(value_or_label)
    v = VOICES.find { |opt| opt[:value].casecmp(value_or_label.to_s) == 0 }
    return v if v

    VOICES.find { |opt| opt[:label].casecmp(value_or_label.to_s) == 0 }
  end

  # Prefer passing voice_value ("openai:alloy") from the client.
  # Keep voice_label working for older clients.
  def self.synthesize_speech(text:, voice_value: nil, voice_label: nil, language: "en")
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
    return "openai:alloy" if raw.blank?

    # Already canonical?
    return raw if raw.include?(":")

    # Legacy openai voice name only (e.g., "alloy")
    openai_candidate = "openai:#{raw.downcase}"
    return openai_candidate if get_voice(openai_candidate)

    # Maybe a display label (e.g., "Alloy" / "Kevin (Kid)")
    opt = get_voice(raw)
    return opt[:value] if opt

    "openai:alloy"
  end
end
