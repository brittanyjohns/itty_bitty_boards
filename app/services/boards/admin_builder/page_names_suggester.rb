module Boards
  module AdminBuilder
    # Proposes the pages of a set — key and name only, no words — so the admin
    # can read and edit the titles before a whole set is drafted under them.
    # One OpenAI call returning `{ pages: [{ key:, name: }] }`.
    #
    # The counterpart to ContextSuggester: same shape, same rule that anything
    # already typed is repeated back unchanged rather than improved. Names that
    # come out of here are fed straight back into SetDrafter as pinned pages.
    #
    # ONLY EVER POPULATES THE FORM — nothing is previewed or built from it.
    #
    # No credit charge: the boards it drafts for are admin-owned.
    class PageNamesSuggester
      class GenerationError < StandardError; end

      # A page name is user-facing and becomes the sub-board's name.
      MAX_NAME_LENGTH = 60

      def initialize(topic:, count:, name: nil, audience: nil, existing: [])
        @topic = topic.to_s.strip
        @name = name.to_s.strip
        @audience = audience.to_s.strip
        @existing = clean_existing(existing)
        @count = count.to_i.clamp(0, SetDrafter::MAX_PAGES)
      end

      def call
        raise GenerationError, "give the board a topic to suggest pages for" if topic.blank? && name.blank?
        return existing.first(count) if count <= existing.size

        parse_response(generate_via_openai)
      end

      private

      attr_reader :topic, :name, :audience, :existing, :count

      # Pages the admin already named. Kept in order and repeated back to the
      # model so what comes out slots into the form without renaming anything.
      def clean_existing(pages)
        seen = Set.new

        Array(pages).filter_map do |page|
          page_name = page[:name].to_s.strip
          key = Keys.normalize(page[:key].presence || page_name)
          next if key.blank?
          next unless seen.add?(key)

          { key: key, name: page_name.presence || key.titleize }
        end
      end

      def generate_via_openai
        client = OpenAiClient.new(
          prompt: topic.presence || name,
          messages: [{ role: "user", content: build_prompt }],
        )
        client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
        result = client.create_chat(true)

        raise GenerationError, "OpenAI returned no content" if result[:content].blank?

        result[:content]
      end

      def build_prompt
        <<~PROMPT
          You are planning a set of AAC (Augmentative and Alternative Communication) boards
          for a nonspeaking communicator: a main board plus #{count} pages, each opened by a
          folder tile on the main board.

          #{name.present? ? "The board is called: #{name}" : ""}
          #{topic.present? ? "The set is about: #{topic}" : ""}
          #{audience.present? ? "It is for: #{audience}" : ""}

          Name the #{count} #{"page".pluralize(count)}. Do not write any words or tiles — titles only.
          #{existing_instruction}
          Rules:
          - "name" is what a teacher or parent would recognize in a list: short title case,
            1-3 words, no punctuation. "Snack Time", "Feelings", "Getting Dressed".
          - "key" is the same page as an identifier: lowercase letters, numbers and
            underscores only.
          - Each page is a distinct subject of the topic — no two pages that would hold the
            same words, and nothing so broad it repeats the main board's core words.

          Respond in JSON format:
          { "pages": [{ "key": "snack_time", "name": "Snack Time" }] }

          Return ONLY the JSON, no other text.
        PROMPT
      end

      def existing_instruction
        return "" if existing.empty?

        listed = existing.map { |page| %("#{page[:name]}") }.join(", ")
        "The first #{existing.size} #{"page".pluralize(existing.size)} are already chosen: " \
          "#{listed}. Repeat #{existing.size == 1 ? "it" : "them"} back first, unchanged, then " \
          "name the rest so they don't overlap.\n"
      end

      def parse_response(raw)
        data = JSON.parse(raw)
        pages = merge_existing(clean_pages(Array(data["pages"])))

        raise GenerationError, "AI returned no usable page names" if pages.empty?

        pages
      rescue JSON::ParserError => e
        raise GenerationError, "Failed to parse AI response: #{e.message}"
      end

      def clean_pages(raw_pages)
        seen = Set.new

        raw_pages.filter_map do |page|
          next unless page.is_a?(Hash)

          page_name = page["name"].to_s.strip.truncate(MAX_NAME_LENGTH)
          key = Keys.normalize(page["key"].presence || page_name)
          next if key.blank?
          next unless seen.add?(key)

          { key: key, name: page_name.presence || key.titleize }
        end
      end

      # What the admin typed is authoritative even when the model rewrote it, so
      # the chosen pages are put back at the front and only unseen suggestions
      # fill the rest.
      def merge_existing(suggested)
        taken = existing.map { |page| page[:key] }.to_set
        extras = suggested.reject { |page| taken.include?(page[:key]) }

        (existing + extras).first(count)
      end
    end
  end
end
