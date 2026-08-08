module Boards
  module AdminBuilder
    # Suggests a board's public description and tags from whatever the form
    # currently holds. One OpenAI call returning `{ description:, tags: }`.
    #
    # Deliberately a separate action from drafting rather than part of it: the
    # admin edits the word list after a draft, so a description generated from
    # the pre-edit list would be stale on arrival.
    #
    # Two constraints come from outside this class and must not be relaxed here:
    #
    #   * **The description is plain text.** `board.description` is rendered as
    #     text on three of four frontend surfaces and as HTML on one, so an HTML
    #     answer shows up as literal tags for most readers.
    #   * **Tags feed the public catalogue's filter.** `Board.public_boards_tags`
    #     is what the frontend offers as filter chips, so an unconstrained
    #     suggester fragments it ("playground", "the playground", "outdoor
    #     play"). The live vocabulary goes into the prompt as the preferred set
    #     and genuinely new tags are rationed.
    #
    # ONLY EVER POPULATES THE FORM. No credit charge: admin-owned boards.
    class MetadataSuggester
      class GenerationError < StandardError; end

      MAX_DESCRIPTION_LENGTH = 300
      MAX_TAGS = 6
      MAX_NEW_TAGS = 2
      MAX_TAG_LENGTH = 30
      # Bounds the prompt. Sorted before truncating so the same vocabulary
      # always produces the same prompt.
      VOCABULARY_SAMPLE_SIZE = 60
      # Enough of the board to describe it without paying for 84 tiles.
      LABEL_SAMPLE_SIZE = 40

      def initialize(name:, topic: nil, audience: nil, labels: [], page_names: [], vocabulary: nil)
        @name = name.to_s.strip
        @topic = topic.to_s.strip
        @audience = audience.to_s.strip
        @labels = Array(labels).map { |label| label.to_s.strip }.reject(&:blank?).first(LABEL_SAMPLE_SIZE)
        @page_names = Array(page_names).map { |page| page.to_s.strip }.reject(&:blank?)
        @vocabulary = clean_vocabulary(vocabulary)
      end

      def call
        if name.blank? && topic.blank? && labels.empty?
          raise GenerationError, "give the board a name, a topic, or some words to work from"
        end

        parse_response(generate_via_openai)
      end

      private

      attr_reader :name, :topic, :audience, :labels, :page_names, :vocabulary

      def clean_vocabulary(supplied)
        values = supplied.nil? ? Board.public_boards_tags : supplied

        Array(values)
          .map { |tag| Board.normalize_tag_value(tag) }
          .reject(&:blank?)
          .uniq
          .sort
          .first(VOCABULARY_SAMPLE_SIZE)
      end

      def generate_via_openai
        client = OpenAiClient.new(
          prompt: name.presence || topic.presence || labels.first.to_s,
          messages: [{ role: "user", content: build_prompt }],
        )
        client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
        result = client.create_chat(true)

        raise GenerationError, "OpenAI returned no content" if result[:content].blank?

        result[:content]
      end

      def build_prompt
        <<~PROMPT
          You are cataloguing an AAC (Augmentative and Alternative Communication) board so
          teachers and parents can find it in a public library of boards.

          #{name.present? ? "The board is called: #{name}" : "The board has no name."}
          #{topic.present? ? "It is about: #{topic}" : ""}
          #{audience.present? ? "It is for: #{audience}" : ""}
          #{page_names.any? ? "It has these pages: #{page_names.join(", ")}" : ""}
          #{labels.any? ? "Words on it: #{labels.join(", ")}" : ""}

          Write two things.

          "description" — one or two sentences saying what the board is for and who would
          use it. Plain text only: no HTML, no markdown, no headings, no bullet points.
          At most #{MAX_DESCRIPTION_LENGTH} characters. Do not list the words on the board.

          "tags" — short lowercase keywords for filtering a board library. Reuse these
          existing tags wherever one fits, rather than inventing a near-synonym:
          #{vocabulary.any? ? vocabulary.join(", ") : "(the library has no tags yet)"}
          Return at most #{MAX_TAGS} tags in total, of which at most #{MAX_NEW_TAGS} may be
          new tags that aren't in the list above. One to three words each, lowercase.

          Respond in JSON format:
          { "description": "A board for talking at the playground.", "tags": ["playground", "outdoor play"] }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      def parse_response(raw)
        data = JSON.parse(raw)
        description = clean_description(data["description"])
        tags = clean_tags(Array(data["tags"]))

        raise GenerationError, "AI returned nothing usable" if description.blank? && tags.empty?

        { description: description, tags: tags }
      rescue JSON::ParserError => e
        raise GenerationError, "Failed to parse AI response: #{e.message}"
      end

      # Models answer a "plain text" request with markup often enough to be
      # worth stripping rather than trusting.
      def clean_description(value)
        value.to_s.gsub(/<[^>]*>/, " ").squish.truncate(MAX_DESCRIPTION_LENGTH)
      end

      # Order is the model's, so its best guess survives the cap. New tags are
      # rationed rather than forbidden — a genuinely new subject deserves one.
      def clean_tags(raw_tags)
        known = vocabulary.to_set
        seen = Set.new
        new_count = 0

        raw_tags.filter_map do |raw|
          tag = Board.normalize_tag_value(raw)
          next if tag.blank? || tag.length > MAX_TAG_LENGTH
          next unless seen.add?(tag)

          unless known.include?(tag)
            next if new_count >= MAX_NEW_TAGS

            new_count += 1
          end

          tag
        end.first(MAX_TAGS)
      end
    end
  end
end
