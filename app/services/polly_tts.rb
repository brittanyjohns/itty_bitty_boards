# frozen_string_literal: true

class PollyTts
  US_ENGLISH = [
    {
      value: "polly:kevin",
      label: "Kevin",
      provider: "polly",
      icon: "child",
      description: "Natural child voice (great for kids using AAC)",
      tags: ["kid", "recommended"],
      engine: "neural",
      language: "en-US",
    },
    {
      value: "polly:joanna",
      label: "Joanna",
      provider: "polly",
      icon: "female",
      description: "Clear, friendly female voice (very easy to understand)",
      tags: ["adult", "recommended"],
      engine: "neural",
      language: "en-US",
    },
    {
      value: "polly:matthew",
      label: "Matthew",
      provider: "polly",
      icon: "male",
      description: "Strong, steady male voice (clear and confident)",
      tags: ["adult", "recommended"],
      engine: "neural",
      language: "en-US",
    },
    {
      value: "polly:ivy",
      label: "Ivy",
      provider: "polly",
      icon: "female",
      description: "Younger-sounding female voice (bright and upbeat)",
      tags: ["adult"],
      engine: "neural",
      language: "en-US",
    },
    {
      value: "polly:joey",
      label: "Joey",
      provider: "polly",
      icon: "male",
      description: "Relaxed male voice (casual and conversational)",
      tags: ["adult"],
      engine: "neural",
      language: "en-US",
    },
    {
      value: "polly:kendra",
      label: "Kendra",
      provider: "polly",
      icon: "female",
      description: "Warm and gentle female voice",
      tags: ["adult"],
      engine: "neural",
      language: "en-US",
    },
    {
      value: "polly:kimberly",
      label: "Kimberly",
      provider: "polly",
      icon: "female",
      description: "Calm and balanced female voice",
      tags: ["adult"],
      engine: "neural",
      language: "en-US",
    },
    {
      value: "polly:ruth",
      label: "Ruth",
      provider: "polly",
      icon: "female",
      description: "Expressive female voice with a rich tone",
      tags: ["adult"],
      engine: "neural",
      language: "en-US",
    },
    {
      value: "polly:salli",
      label: "Salli",
      provider: "polly",
      icon: "female",
      description: "Classic, friendly female voice",
      tags: ["adult"],
      engine: "neural",
      language: "en-US",
    },
  ].freeze

  UK_ENGLISH = [
    {
      value: "polly:amy",
      label: "Amy",
      provider: "polly",
      icon: "female",
      description: "British female voice (clear and friendly)",
      tags: ["adult"],
      engine: "neural",
      language: "en-GB",
    },
    {
      value: "polly:brian",
      label: "Brian",
      provider: "polly",
      icon: "male",
      description: "British male voice (deep and steady)",
      tags: ["adult"],
      engine: "neural",
      language: "en-GB",
    },
    {
      value: "polly:emma",
      label: "Emma",
      provider: "polly",
      icon: "female",
      description: "British female voice (neutral tone)",
      tags: ["adult"],
      engine: "neural",
      language: "en-GB",
    },

  ].freeze

  SPANISH = [
    {
      value: "polly:lupe",
      label: "Lupe",
      provider: "polly",
      icon: "female",
      description: "US Spanish female voice (clear and natural)",
      tags: ["adult", "recommended"],
      engine: "neural",
      language: "es-US",
    },
    {
      value: "polly:pedro",
      label: "Pedro",
      provider: "polly",
      icon: "male",
      description: "US Spanish male voice",
      tags: ["adult"],
      engine: "neural",
      language: "es-US",
    },
    {
      value: "polly:lucia",
      label: "Lucia",
      provider: "polly",
      icon: "female",
      description: "Spanish (Spain) female voice",
      tags: ["adult"],
      engine: "neural",
      language: "es-ES",
    },
    {
      value: "polly:sergio",
      label: "Sergio",
      provider: "polly",
      icon: "male",
      description: "Spanish (Spain) male voice",
      tags: ["adult"],
      engine: "neural",
      language: "es-ES",
    },

  ].freeze

  VOICES = (US_ENGLISH + UK_ENGLISH + SPANISH).freeze

  def initialize(region: ENV.fetch("AWS_REGION", "us-east-1"))
    @client = Aws::Polly::Client.new(region: region)
  end

  # Returns a Tempfile containing an mp3
  def synthesize_mp3!(text:, voice_id: "Kevin", engine: "neural")
    # Polly SynthesizeSpeech limits: 3000 billed chars / 6000 total chars. :contentReference[oaicite:3]{index=3}
    raise ArgumentError, "text too long" if text.to_s.length > 6000
    voice_id = voice_id.to_s.strip&.capitalize if voice_id.present?
    voice_id = "Kevin" if voice_id.blank?

    resp = @client.synthesize_speech(
      text: text,
      text_type: "text",
      output_format: "mp3",
      voice_id: voice_id,
      engine: engine,
    )

    tmp = Tempfile.new(["polly-", ".mp3"], binmode: true)
    IO.copy_stream(resp.audio_stream, tmp)
    tmp.rewind
    tmp
  end
end
