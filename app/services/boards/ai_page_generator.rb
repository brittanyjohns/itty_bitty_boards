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

    def generate_via_openai
      client = OpenAiClient.new(
        prompt: @interests.first,
        messages: [{ role: "user", content: build_prompt }],
      )
      client.instance_variable_set(:@model, OpenAiClient::GTP_MODEL)
      result = client.create_chat(true)

      raise GenerationError, "OpenAI returned no content" if result[:content].blank?

      result[:content]
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
        - Words should support COMMUNICATION, not just labeling — include action words and descriptors, not just "types of #{@interests.first}"
        - Keep words short (1-2 words max per tile)
        - Make words age-appropriate and concrete
        - Include the original interest word(s) if they make good tiles
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
