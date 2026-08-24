module Boards
  module AdminBuilder
    # The one OpenAI call every drafter on the admin Board Builder makes.
    #
    # SetDrafter, WordListDrafter and PageDrafter had three byte-identical copies
    # of this, which is how they ended up on a different model and a different
    # temperature from each other by accident rather than decision.
    module Drafting
      # These boards are authored by an admin, a few times a day, and every one
      # of them ships to real communicators — so this path is worth a better
      # model than the app's general-purpose default. Overridable per
      # environment without a deploy.
      MODEL = ENV.fetch("OPENAI_ADMIN_BUILDER_MODEL", OpenAiClient::GTP_5_MODEL).freeze

      # Drafting is a counting exercise as much as a creative one — "EXACTLY 24
      # tiles, no near-duplicates, this part-of-speech balance" — and the
      # provider default wanders on all three. Set to "" to send no temperature
      # at all. Ignored entirely on a reasoning model (see REASONING_MODEL).
      TEMPERATURE = ENV.fetch("OPENAI_ADMIN_BUILDER_TEMPERATURE", "0.4").freeze

      # gpt-5 and the o-series accept ONLY the default temperature (1) and 400
      # anything else, so sending one is a guaranteed wasted round trip that
      # then looks like an empty draft. Matched on the model NAME rather than an
      # allow-list, so an ENV override to another gpt-5 variant is covered.
      REASONING_MODEL = MODEL.match?(/\A(gpt-5|o\d)/i)

      # Those same models think for as long as the effort asks for, and at the
      # provider default a 24-tile draft did not finish inside the 60s client
      # timeout at all. Drafting is a tightly-specified list against a json
      # schema, not a hard reasoning problem: measured against the same prompt,
      # "minimal" answered in 9s where "low" took 48s and the provider default
      # timed out — and the minimal list was the better board (more core, more
      # negation, fewer topic nouns). Raise it here if drafts get worse.
      REASONING_EFFORT = ENV.fetch("OPENAI_ADMIN_BUILDER_REASONING_EFFORT", "minimal").freeze

      # Headroom over the 60s default, which a set draft does not fit inside:
      # the biggest one (a root plus four pages, in a single call) measured 55s
      # at minimal effort and 83s at low. An admin waits on this in the request
      # cycle, so it buys headroom rather than patience.
      REQUEST_TIMEOUT = Integer(ENV.fetch("OPENAI_ADMIN_BUILDER_TIMEOUT", 120))

      # The prompt text itself now lives in `Prompts::Aac`, so the user-facing
      # word paths can share it — it was written here, but nothing a customer
      # touches was getting any of it. These stay as the names every drafter
      # and spec already references.
      #
      # The model, temperature, reasoning effort and timeout above are NOT
      # shared: they are measured decisions about a bigger model doing a harder
      # job (see .claude-notes/board-builder.md).
      SYSTEM_PROMPT = Prompts::Aac::SYSTEM_PROMPT
      WORD_RULES = Prompts::Aac::WORD_RULES

      # Ordering is asked for here as well as enforced in Ruby by
      # `TileArrangement`: a model composing a block of verbs picks better verbs
      # than one emitting them scattered between nouns.
      def self.part_of_speech_rules
        Prompts::Aac.part_of_speech_rules(arrangement_rule: TileArrangement::PROMPT_RULE)
      end

      module_function

      # Returns the response content, or nil. Each drafter raises its own
      # GenerationError on nil — the error class is part of that drafter's
      # contract with its controller action.
      #
      # `schema` is an OpenAI Structured Outputs `json_schema` value. It pins the
      # part_of_speech enum and the tile shape at the API rather than in prose,
      # which is the difference between a bad value being impossible and being
      # quietly downgraded to grey by the drafter's own fallback.
      #
      # Two retries, both for the same reason: MODEL and TEMPERATURE are
      # ENV-tunable, not every model accepts a custom temperature or a json
      # schema, and `create_chat` swallows an API error into a log line and
      # hands back nil content — so a rejected parameter looks exactly like "the
      # AI had nothing to say" and would take drafting down until someone read
      # the logs. Same reasoning as the image-model fallback in
      # `OpenAiClient#create_image`.
      def chat(prompt:, content:, schema: nil)
        result = with_temperature_retry(prompt: prompt, content: content, schema: schema)
        return result if result.present?
        return nil if schema.blank?

        Rails.logger.warn("[AdminBuilder::Drafting] no content from #{MODEL} with a json schema " \
                          "— retrying without it")
        with_temperature_retry(prompt: prompt, content: content, schema: nil)
      end

      def with_temperature_retry(prompt:, content:, schema:)
        result = call(prompt: prompt, content: content, schema: schema, temperature: temperature)
        return result if result.present?
        return nil if temperature.blank?

        Rails.logger.warn("[AdminBuilder::Drafting] no content from #{MODEL} at " \
                          "temperature #{TEMPERATURE} — retrying without it")
        call(prompt: prompt, content: content, schema: schema, temperature: nil)
      end

      # nil on a reasoning model: it would be rejected, and the retry that
      # follows a rejection is a whole extra minute of an admin's afternoon.
      def temperature
        return nil if REASONING_MODEL

        TEMPERATURE.presence
      end

      def call(prompt:, content:, schema:, temperature:)
        opts = { prompt: prompt, messages: messages_for(content), request_timeout: REQUEST_TIMEOUT }
        opts[:temperature] = temperature.to_f if temperature.present?
        opts[:reasoning_effort] = REASONING_EFFORT if REASONING_MODEL && REASONING_EFFORT.present?
        opts[:response_format] = { type: "json_schema", json_schema: schema } if schema.present?

        # Splatted, not passed as one positional hash. `OpenAiClient#initialize`
        # takes a positional `opts` either way, but every caller in the codebase
        # writes it as keywords and the specs stub it that way — handing it a
        # bare Hash moves the argument from kwargs to args and silently breaks
        # those stubs.
        client = OpenAiClient.new(**opts)
        client.instance_variable_set(:@model, MODEL)
        client.create_chat(true)[:content].presence
      end

      def messages_for(content)
        [
          { role: "system", content: SYSTEM_PROMPT },
          { role: "user", content: content },
        ]
      end

      # Builds a Structured Outputs schema for a list of tiles. Strict mode
      # requires EVERY property to be listed in `required` and forbids extra
      # ones, so what is optional in the plan is modelled as nullable here
      # rather than omitted — a tile that opens nothing sends `"links_to": null`.
      #
      # `links:` is false for WordListDrafter, which has no concept of a link and
      # would only invite the model to invent page keys that don't exist.
      def tile_schema(links: true)
        properties = {
          label: { type: "string" },
          part_of_speech: { type: "string", enum: ColorHelper::PARTS_OF_SPEECH },
          proper_noun: { type: "boolean" },
        }
        properties[:links_to] = { type: %w[string null] } if links

        {
          type: "object",
          additionalProperties: false,
          required: properties.keys.map(&:to_s),
          properties: properties,
        }
      end
    end
  end
end
