# app/models/ai_board_formatter.rb
# frozen_string_literal: true

class AiBoardFormatter
  def self.call(...) = new(...).call

  # name: Board name (for context only)
  # columns: max grid columns for the largest screen (Integer, informational)
  # rows: hint only (Integer, informational)
  # existing: [{ word:, size: [w,h], board_type: <optional> }, ...]
  # maintain_existing: true/false (informational; placement is now deterministic)
  def initialize(name:, columns:, rows:, existing:, maintain_existing:)
    @name = name.to_s
    @columns = columns.to_i
    @rows = rows.to_i
    @existing = existing || []
    @maintain_existing = !!maintain_existing
  end

  # Returns a parsed Hash like:
  # {
  #   "ordered_words" => [
  #     { "word"=>"I", "size"=>[1,1], "frequency"=>"high", "part_of_speech"=>"pronoun" },
  #     ...
  #   ],
  #   "personable_explanation"  => "...",
  #   "professional_explanation"=> "..."
  # }
  #
  # Returns nil on error.
  def call
    text = prompt
    raw = request_openai(text)
    payload = parse_jsonish(raw)
    normalize(payload)
  rescue => e
    Rails.logger.error("[AiBoardFormatter] #{e.class}: #{e.message}")
    nil
  end

  private

  def prompt
    words = @existing.map { |w| w[:word].to_s }.reject(&:blank?)

    <<~PROMPT
      You are organizing words for an AAC communication board.

      Return ONLY a single valid JSON object. No prose, no markdown, no comments.

      Your job is to ORDER the supplied words and assign each one a tile size.
      You do NOT assign x/y positions — placement is computed downstream.

      AAC ordering rules (apply in this priority):
      1. Communication starters and high-frequency core words first
         (e.g. "I", "you", "want", "more", "stop", "help", "yes", "no", "go").
      2. Common action words next (verbs like "eat", "play", "look").
      3. Descriptive words next (adjectives, feelings, colors).
      4. Specific or lower-frequency words last (nouns, named items).

      Tile sizing rules:
      - Default size is [1, 1].
      - You may use [2, 1] for up to 2 of the most important phrase-style
        tiles (e.g. "I want", "help"). Only when it clearly helps motor
        planning.
      - Never use [2, 2] or any size larger than [2, 1].
      - Keep sizing consistent and predictable — most tiles should be [1, 1].

      Word inclusion rules:
      - Use every supplied word exactly once.
      - Do not invent, drop, duplicate, or rename words.
      - Preserve the original spelling and casing of each word.

      Frequency values must be one of: "high", "medium", "low".
      Part of speech should be one of: "pronoun", "noun", "verb",
      "adjective", "adverb", "preposition", "conjunction", "interjection",
      "determiner", "phrase", "other".

      Grid hint (informational only — placement is computed downstream):
      - Target columns: #{@columns}
      - Approximate rows: #{@rows}

      Words to order:
      #{words.join(", ")}

      Required JSON shape:
      {
        "ordered_words": [
          { "word": "I",    "size": [1,1], "frequency": "high",   "part_of_speech": "pronoun" },
          { "word": "want", "size": [1,1], "frequency": "high",   "part_of_speech": "verb" }
        ],
        "personable_explanation":  "One short sentence the caregiver will read.",
        "professional_explanation": "One short sentence explaining the AAC reasoning."
      }
    PROMPT
  end

  def request_openai(text)
    messages = [{ role: "user", content: [{ type: "text", text: text }] }]
    OpenAiClient.new({
      messages: messages,
      response_format: { type: "json_object" },
    }).create_completion&.dig(:content)
  end

  # 1) strips ``` and ```json fences
  # 2) tries strict JSON
  # 3) retries after removing trailing commas
  def parse_jsonish(raw)
    return nil if raw.blank?

    str = raw.to_s.dup
    str.sub!(/\A```json\s*/i, "")
    str.sub!(/\A```\s*/i, "")
    str.sub!(/```$/i, "")
    str.strip!

    begin
      JSON.parse(str)
    rescue JSON::ParserError
      cleaned = str.gsub(/,(\s*[}\]])/, '\1')
      JSON.parse(cleaned)
    end
  rescue JSON::ParserError => e
    Rails.logger.error("[AiBoardFormatter] parse failed: #{e.message}")
    nil
  end

  # Accepts either the new "ordered_words" shape or the legacy "grid" shape
  # (back-compat with prompts/responses that still include "position").
  # Always returns a hash with "ordered_words" populated.
  def normalize(payload)
    return nil if payload.blank?

    items =
      if payload["ordered_words"].is_a?(Array)
        payload["ordered_words"]
      elsif payload["grid"].is_a?(Array)
        payload["grid"]
      else
        []
      end

    ordered = items.filter_map do |item|
      next unless item.is_a?(Hash)
      word = item["word"].to_s.strip
      next if word.blank?

      size = Array(item["size"])
      w = size[0].to_i
      h = size[1].to_i
      w = 1 if w < 1
      h = 1 if h < 1

      {
        "word" => word,
        "size" => [w, h],
        "frequency" => item["frequency"].presence,
        "part_of_speech" => item["part_of_speech"].presence,
      }
    end

    {
      "ordered_words" => ordered,
      "personable_explanation" => payload["personable_explanation"].presence,
      "professional_explanation" => payload["professional_explanation"].presence,
    }
  end
end
