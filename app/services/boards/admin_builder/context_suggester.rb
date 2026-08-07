module Boards
  module AdminBuilder
    # Infers a board's topic and audience from its name — and from the words
    # already on it, when there are any. One OpenAI call returning
    # `{ topic:, audience: }`.
    #
    # Both fields exist to be fed to other prompts rather than to be stored
    # prose: `topic` is what completes "<label> in the context of ___" when art
    # is generated (the difference between a playground *swing* and a mood
    # swing), and `audience` steers the word-list draft. So the prompt asks for
    # a short noun phrase in each, not a sentence.
    #
    # ONLY EVER POPULATES THE FORM — like WordListDrafter, this is a starting
    # point a human edits before anything is previewed or built.
    #
    # No credit charge: the boards it drafts for are admin-owned.
    class ContextSuggester
      class GenerationError < StandardError; end

      # Enough of the word list to infer a subject without paying for a whole
      # 84-tile board in the prompt.
      WORD_SAMPLE_SIZE = 24

      # These are prompt fragments, not display copy — a runaway response would
      # end up inside every art prompt for the board.
      MAX_TOPIC_LENGTH = 120
      MAX_AUDIENCE_LENGTH = 120

      def initialize(name:, words: nil)
        @name = name.to_s.strip
        @words = word_sample(words)
      end

      def call
        if name.blank? && words.empty?
          raise GenerationError, "give the board a name, or some words, to work from"
        end

        parse_response(generate_via_openai)
      end

      private

      attr_reader :name, :words

      def word_sample(words)
        words.to_s.split("\n").filter_map do |line|
          label = line.split("|").first.to_s.strip
          label.presence
        end.first(WORD_SAMPLE_SIZE)
      end

      def generate_via_openai
        client = OpenAiClient.new(
          prompt: name.presence || words.first.to_s,
          messages: [{ role: "user", content: build_prompt }],
        )
        client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
        result = client.create_chat(true)

        raise GenerationError, "OpenAI returned no content" if result[:content].blank?

        result[:content]
      end

      def build_prompt
        <<~PROMPT
          You are setting up an AAC (Augmentative and Alternative Communication) board for a
          nonspeaking communicator.

          #{name.present? ? "The board is called: #{name}" : "The board has no name yet."}
          #{words.any? ? "Words already on it: #{words.join(", ")}" : ""}

          Infer two things about it.

          "topic" — the subject or setting of the board, as a short noun phrase that can be
          dropped into the sentence "a picture of <word> in the context of ___". Write it so
          that sentence reads naturally: "the playground", "getting dressed in the morning",
          "a trip to the doctor". Not a title, not a sentence, no trailing punctuation. If the
          board name is already a good topic, say it plainly rather than embellishing it.

          "audience" — who the board is for, as a short noun phrase: "an early communicator",
          "a preschooler who is starting to combine words", "a teenager using full sentences".
          Infer it from the board's subject and vocabulary. When there's nothing to go on,
          answer "an early communicator" rather than guessing something specific.

          Respond in JSON format:
          { "topic": "the playground", "audience": "an early communicator" }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      def parse_response(raw)
        data = JSON.parse(raw)
        topic = clean(data["topic"], MAX_TOPIC_LENGTH)
        audience = clean(data["audience"], MAX_AUDIENCE_LENGTH)

        raise GenerationError, "AI returned no usable topic" if topic.blank?

        { topic: topic, audience: audience }
      rescue JSON::ParserError => e
        raise GenerationError, "Failed to parse AI response: #{e.message}"
      end

      # Models like to answer a "short noun phrase" request with a sentence.
      # Strip the trailing full stop and cap the length so neither value can
      # bloat the prompts these get pasted into.
      def clean(value, limit)
        value.to_s.strip.delete_suffix(".").strip.truncate(limit)
      end
    end
  end
end
