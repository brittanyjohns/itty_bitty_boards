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

      # Sent ahead of every drafter's own prompt. The per-drafter prompts say
      # what to build; this says who is building it and what is never negotiable
      # whichever button was pressed. Kept short: it is prepended to four
      # different prompts, and a long preamble competes with the instructions
      # that actually differ between them.
      SYSTEM_PROMPT = <<~PROMPT.freeze
        You are a speech-language pathologist who builds AAC (Augmentative and
        Alternative Communication) grid boards for nonspeaking communicators.

        You are choosing which words earn a cell on a fixed grid a child will use
        every day — not writing a vocabulary list about a topic. A board is judged
        on what it lets someone SAY: request, refuse, comment, direct, repair. A
        board that can only name things has failed even if every word on it is
        correct.

        These hold for every request, whatever else the instructions ask for:
        - Return the EXACT tile count asked for. The grid is fixed and a partial
          last row is visible dead cells on a real board.
        - Every tile carries a part_of_speech from the list you are given. It sets
          the tile's Modified Fitzgerald Key colour, so a wrong one miscolours the
          board.
        - Respond with JSON only — no prose, no code fences, no commentary.
      PROMPT

      # The word-selection rules every drafter shares, so the four prompts can't
      # drift apart on what makes a good tile the way they once drifted on model
      # and temperature. A drafter adds its own lines around this — what a page
      # owes the set, what the main board owes every page — but never restates
      # one of these.
      #
      # These are the rules that separate a board from a word list. Each one is
      # here because a draft failed on it: pages of nouns nobody can say anything
      # about, boards with no way to refuse, a preschool board that offered
      # "Tuesday" and "purple" but not "again".
      WORD_RULES = <<~RULES.freeze
        - Favour words that can finish many different sentences over words that
          finish one. "want", "more", "go" and "different" earn a cell on almost
          any board; "cheeseburger" earns one only on a board about lunch.
        - Every board needs a way to object and a way to redirect. Include at
          least one of: no, not, stop, don't like. And at least one of: again,
          different, something else, all done.
        - A noun earns a cell if the communicator can say something ABOUT it, not
          only name it. Skip nouns that exist to be labelled.
        - No closed sets as filler: no letters, digits, days of the week, months,
          or a run of colours, unless the topic is that thing.
        - Match the register to who this is for. If an age or setting is given,
          the words sound like that person's life — not a generic child's.
        - No near-duplicates ("happy" and "glad", "big" and "large"). Each tile
          costs a cell.
        - Keep each label short — 1-2 words.
        - A label is display text, not an identifier: separate words with a plain
          space, never an underscore.
      RULES

      # The part-of-speech clause, shared for the same reason. Ordering is asked
      # for here as well as enforced in Ruby by `TileArrangement`: a model
      # composing a block of verbs picks better verbs than one emitting them
      # scattered between nouns.
      def self.part_of_speech_rules
        <<~RULES
          - Give every tile a part_of_speech from exactly this list:
            #{ColorHelper::PARTS_OF_SPEECH.join(", ")}
          - Classify by communicative function, not strict grammar: "more", "yes" and
            "please" are social; "no", "not" and "stop" are important_function.
          #{TileArrangement::PROMPT_RULE.rstrip}
        RULES
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
