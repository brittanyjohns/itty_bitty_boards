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
      # at all.
      TEMPERATURE = ENV.fetch("OPENAI_ADMIN_BUILDER_TEMPERATURE", "0.4").freeze

      module_function

      # Returns the response content, or nil. Each drafter raises its own
      # GenerationError on nil — the error class is part of that drafter's
      # contract with its controller action.
      #
      # The retry exists because MODEL and TEMPERATURE are both ENV-tunable and
      # not every model accepts a custom temperature. `create_chat` swallows an
      # API error into a debug log and hands back nil content, so without this a
      # rejected temperature would look exactly like "the AI had nothing to say"
      # and take drafting down until someone read the logs. Same reasoning as
      # the image-model fallback in OpenAiClient#create_image.
      def chat(prompt:, content:)
        result = call(prompt: prompt, content: content, temperature: TEMPERATURE.presence)
        return result if result.present?
        return nil if TEMPERATURE.blank?

        Rails.logger.warn("[AdminBuilder::Drafting] no content from #{MODEL} at " \
                          "temperature #{TEMPERATURE} — retrying without it")
        call(prompt: prompt, content: content, temperature: nil)
      end

      def call(prompt:, content:, temperature:)
        opts = { prompt: prompt, messages: [{ role: "user", content: content }] }
        opts[:temperature] = temperature.to_f if temperature.present?

        # Splatted, not passed as one positional hash. `OpenAiClient#initialize`
        # takes a positional `opts` either way, but every caller in the codebase
        # writes it as keywords and the specs stub it that way — handing it a
        # bare Hash moves the argument from kwargs to args and silently breaks
        # those stubs.
        client = OpenAiClient.new(**opts)
        client.instance_variable_set(:@model, MODEL)
        client.create_chat(true)[:content].presence
      end
    end
  end
end
