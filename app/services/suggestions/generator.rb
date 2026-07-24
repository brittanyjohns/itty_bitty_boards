require "json"

module Suggestions
  # Builds the prompt, calls OpenAI in JSON mode, and normalizes the result.
  #
  # Contract: ALWAYS returns an array of plain strings. Never nil, never raises.
  # A parent mid-onboarding must never see an error because OpenAI hiccuped —
  # the caller renders 200 with an empty array and the UI degrades quietly.
  #
  # Mirrors CoachingPromptGenerator's shape (JSON mode, staging fallback, broad
  # rescue), which is the established pattern for non-critical AI in this app.
  class Generator
    MODEL = ENV.fetch("OPENAI_SUGGESTIONS_MODEL", OpenAiClient::GTP_MODEL)

    # Deliberately shorter than OpenAiClient's 60s default: this is interactive,
    # and a parent staring at a spinner would rather be told "not right now".
    # NOTE: request_timeout is a CLIENT option in ruby-openai, not a chat
    # parameter — hence our own client below rather than OpenAiClient's.
    TIMEOUT_SECONDS = Integer(ENV.fetch("OPENAI_SUGGESTIONS_TIMEOUT", 15))

    # Used in staging and test so neither burns paid OpenAI calls. Matches the
    # AppEnv.staging? stub pattern documented in the backend CLAUDE.md.
    FIXTURES = {
      about_me: [
        "Loves trains and will show you every single one that goes past.",
        "Says hello with a big wave, and a high five if you offer one.",
        "Happiest with music on and a bit of room to move.",
      ],
    }.freeze

    def self.call(entry, context:, locale: "en")
      new(entry, context: context, locale: locale).call
    end

    # Neither staging nor the test suite may make paid OpenAI calls. Public so
    # specs exercising the live path can stub it to false.
    def self.use_fixtures?
      AppEnv.staging? || Rails.env.test?
    end

    # Our own client rather than OpenAiClient's, purely for the shorter
    # interactive timeout — request_timeout is a client option in ruby-openai.
    def self.openai_client
      @openai_client ||= OpenAI::Client.new(
        access_token: ENV.fetch("OPENAI_ACCESS_TOKEN"),
        log_errors: true,
        request_timeout: TIMEOUT_SECONDS,
      )
    end

    def initialize(entry, context:, locale: "en")
      @entry = entry
      @context = context || {}
      @locale = locale.presence || "en"
    end

    def call
      return fixtures if self.class.use_fixtures?

      normalize(request_suggestions)
    rescue => e
      Rails.logger.error "[Suggestions::Generator] #{e.class}: #{e.message}"
      []
    end

    private

    def fixtures
      normalize(FIXTURES.fetch(@entry[:template], []))
    end

    def request_suggestions
      response = self.class.openai_client.chat(
        parameters: {
          model: MODEL,
          messages: [
            { role: "system", content: system_prompt },
            { role: "user", content: user_prompt },
          ],
          response_format: { type: "json_object" },
        },
      )

      content = response.dig("choices", 0, "message", "content")
      return [] if content.blank?

      parsed = JSON.parse(content)
      Array(parsed["suggestions"])
    rescue JSON::ParserError => e
      Rails.logger.warn "[Suggestions::Generator] bad JSON: #{e.message}"
      []
    end

    def normalize(raw)
      Array(raw)
        .select { |s| s.is_a?(String) }
        .map { |s| s.strip.first(@entry[:max_chars]) }
        .reject(&:blank?)
        .first(@entry[:count])
    end

    # Voice rules come from marketing/.claude-notes/brand-voice.md. The
    # prohibitions are not stylistic — About Me is published publicly on a
    # child's MySpeak page, so an invented "fact" becomes a public claim about
    # a real child.
    def system_prompt
      <<~PROMPT
        You help a parent or teacher write a short public "About Me" blurb for a
        nonspeaking communicator who uses SpeakAnyWay, an AAC (augmentative and
        alternative communication) app.

        Write in the warm, plain voice of a parent introducing their child to a
        friendly stranger. Be concrete and specific, never generic. Prefer
        "Loves trains and will show you every one that goes past" over "is a
        happy child who enjoys activities".

        Rules you must follow:
        - Respond in this language: #{@locale}
        - Exactly #{@entry[:count]} suggestions, 1-2 sentences each, under #{@entry[:max_chars]} characters each.
        - NEVER invent a fact about the child. Use only the details provided.
          Where you have few details, write a warm opening the parent can finish
          themselves rather than guessing.
        - Never diagnose, imply a diagnosis, or mention any medical condition.
        - Never use the word "autism".
        - Say "nonspeaking", never "nonverbal". Say "communicator", never "AAC user".
        - No inspiration porn, no "look how amazing", no toxic positivity, and
          never frame anyone as fixing or rescuing the child.
        - If you name the product, it is always written "SpeakAnyWay".

        Respond with JSON only, in exactly this shape:
        {"suggestions": ["...", "...", "..."]}
      PROMPT
    end

    def user_prompt
      return "No details are known yet. Write warm, general openings." if @context.blank?

      lines = @context.map { |key, value| "#{key.to_s.humanize}: #{value}" }
      "What we know about this communicator:\n#{lines.join("\n")}"
    end
  end
end
