module Boards
  class AiPageGenerator
    TARGET_TILES = 10
    MIN_TILES = 6
    MAX_TILES = 14

    class GenerationError < StandardError; end

    def initialize(interests:, profile: nil, tile_count: TARGET_TILES)
      @interests = Array(interests).map(&:to_s).reject(&:blank?)
      @profile = profile
      @tile_count = tile_count.clamp(MIN_TILES, MAX_TILES)
    end

    def call
      raise GenerationError, "no interests provided" if @interests.empty?

      response = generate_via_openai
      parse_response(response)
    end

    private

    # The shared AAC kernel goes in the system slot, and the page-specific
    # instructions in the user slot. This prompt used to be one user message
    # with its own hand-written version of the rules, so an interest page was
    # drafted by a model that had been told less about AAC than the admin
    # builder tells it — for the same job.
    SCHEMA = {
      name: "aac_interest_page",
      strict: true,
      schema: {
        type: "object",
        additionalProperties: false,
        required: %w[name tiles],
        properties: {
          name: { type: "string" },
          tiles: {
            type: "array",
            items: {
              type: "object",
              additionalProperties: false,
              required: ["label"],
              properties: { label: { type: "string" } },
            },
          },
        },
      },
    }.freeze

    def generate_via_openai
      result = chat(schema: SCHEMA)

      # Not every model accepts a json_schema, and create_chat swallows an API
      # error into nil content — so a rejected schema is indistinguishable from
      # "the model had nothing to say". Same ladder as AdminBuilder::Drafting.
      if result[:content].blank?
        Rails.logger.warn("[AiPageGenerator] no content with a json schema — retrying without it")
        result = chat(schema: nil)
      end

      raise GenerationError, "OpenAI returned no content" if result[:content].blank?

      result[:content]
    end

    def chat(schema:)
      opts = {
        prompt: @interests.first,
        messages: [
          { role: "system", content: system_prompt },
          { role: "user", content: build_prompt },
        ],
        temperature: OpenAiClient::WORD_SUGGESTION_TEMPERATURE.presence&.to_f,
      }.compact
      opts[:response_format] = { type: "json_schema", json_schema: schema } if schema

      client = OpenAiClient.new(**opts)
      client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
      client.create_chat(true)
    end

    def system_prompt
      <<~PROMPT
        #{Prompts::Aac::SYSTEM_PROMPT}
        Word selection rules:
        #{Prompts::Aac::WORD_RULES}
      PROMPT
    end

    def build_prompt
      interest_list = @interests.join(", ")
      guidance = @profile&.prompt_guidance.presence

      <<~PROMPT
        You are building an AAC (Augmentative and Alternative Communication) board page for a nonspeaking communicator.

        The page topic is based on these interest words: #{interest_list}

        Generate exactly #{@tile_count} words/short phrases for AAC board tiles related to this topic.

        Requirements:
        - Include a MIX of word types: nouns (things), verbs (actions), and adjectives (descriptors)
        - Make words concrete, and include the original interest word(s) if they make good tiles
        #{guidance ? "- #{guidance}" : ""}

        Respond in JSON format:
        {
          "name": "Topic Name",
          "tiles": [
            { "label": "word1" },
            { "label": "word2" }
          ]
        }

        Return ONLY the JSON, no other text.
      PROMPT
    end

    def parse_response(raw)
      data = JSON.parse(raw)
      name = data["name"].to_s.presence || @interests.first.capitalize
      tiles = Array(data["tiles"]).first(@tile_count).filter_map do |tile|
        label = (tile["label"] || tile["word"]).to_s.strip
        next if label.blank?

        { label: label }
      end

      raise GenerationError, "AI returned fewer than #{MIN_TILES} usable tiles" if tiles.size < MIN_TILES

      { name: name, tiles: tiles }
    rescue JSON::ParserError => e
      raise GenerationError, "Failed to parse AI response: #{e.message}"
    end
  end
end
