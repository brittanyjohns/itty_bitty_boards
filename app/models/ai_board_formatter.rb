# app/models/ai_board_formatter.rb
# frozen_string_literal: true

# Orders the words already on a board so the grid reads well, and nothing else.
#
# **This returns an ORDER.** It does not choose tile sizes, positions, columns
# or rows, and it never adds or drops a word. `Board#format_board_with_ai` lays
# the returned order out row-major at a uniform 1x1, then hands it to
# `Boards::TileArrangement` for the part-of-speech banding — so the only thing
# this class can get wrong is the sequence.
#
# It used to be allowed to make "up to 2" tiles two cells wide. The model took
# that permission on every run and picked which two, which put a board's tile
# count out of step with its grid: 48 tiles on 8 columns stopped being 6 exact
# rows and became 7, the last one holding two tiles. That extra row is also what
# broke `settings["disable_scroll"]` — the frontend locks a board to the screen
# only while a row stays readable, and an inflated row count pushes it under the
# floor, so the board silently starts scrolling. A tile size is a grid-wide
# decision; it is not the sort of thing to let a language model take per word.
class AiBoardFormatter
  FREQUENCIES = %w[high medium low].freeze

  def self.call(...) = new(...).call

  # name: Board name (for context only)
  # columns: max grid columns for the largest screen (Integer, informational)
  # rows: hint only (Integer, informational)
  # existing: [{ word:, board_type: <optional> }, ...]
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
  #     { "word"=>"I", "frequency"=>"high", "part_of_speech"=>"pronoun" },
  #     ...
  #   ],
  #   "personable_explanation"  => "...",
  #   "professional_explanation"=> "..."
  # }
  #
  # Returns nil on error.
  def call
    raw = request_openai(prompt)
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
      Order the words on an AAC communication board called "#{@name}".

      Your job is to ORDER the supplied words and give each one a part of
      speech. You do NOT choose tile sizes and you do NOT assign x/y positions:
      every tile is exactly one cell, and placement is computed downstream from
      the order you return.

      #{Prompts::Aac.part_of_speech_rules(arrangement_rule: Boards::TileArrangement::PROMPT_RULE)}
      Within each group, order the words yourself:
      - Highest-frequency core words first — the ones a communicator reaches for
        under pressure ("I", "you", "want", "more", "stop", "help", "go").
      - Keep words that are used together next to each other, so a communicator
        learns one motor path for the pair: up/down, hot/cold, happy/sad,
        here/there, big/little.
      - Specific, lower-frequency words last.

      Word inclusion rules:
      - Use every supplied word exactly once.
      - Do not invent, drop, duplicate, or rename words.
      - Preserve the original spelling and casing of each word.

      Frequency values must be one of: #{FREQUENCIES.join(", ")}.

      Grid (informational only — placement is computed downstream):
      - Columns: #{@columns}
      - Approximate rows: #{@rows}

      Words to order:
      #{words.join(", ")}
    PROMPT
  end

  # Pins the response shape with Structured Outputs rather than a sentence
  # describing JSON: `json_object` only says "some JSON", and a well-formed
  # object with the wrong keys is legal — which is what `parse_jsonish` below
  # grew up to paper over.
  #
  # Deliberately carries no `size`: a size the model cannot express is a size it
  # cannot get wrong.
  RESPONSE_SCHEMA = {
    name: "ai_board_order",
    strict: true,
    schema: {
      type: "object",
      additionalProperties: false,
      required: %w[ordered_words personable_explanation professional_explanation],
      properties: {
        "ordered_words" => {
          type: "array",
          items: {
            type: "object",
            additionalProperties: false,
            required: %w[word frequency part_of_speech],
            properties: {
              "word" => { type: "string" },
              "frequency" => { type: "string", enum: FREQUENCIES },
              "part_of_speech" => { type: "string", enum: ColorHelper::PARTS_OF_SPEECH },
            },
          },
        },
        "personable_explanation" => { type: "string" },
        "professional_explanation" => { type: "string" },
      },
    },
  }.freeze

  # Retries once without the schema for the same reason every other
  # schema-using caller does: not every model accepts a `json_schema`, and
  # `create_completion` turns an API error into nil content, so a rejected
  # parameter is indistinguishable from "the model had nothing to say".
  def request_openai(text)
    messages = [
      { role: "system", content: Prompts::Aac::SYSTEM_PROMPT },
      { role: "user", content: text },
    ]

    result = completion(messages, { type: "json_schema", json_schema: RESPONSE_SCHEMA })
    return result if result.present?

    Rails.logger.warn("[AiBoardFormatter] no content with a json schema — retrying without it")
    completion(messages, { type: "json_object" })
  end

  def completion(messages, response_format)
    OpenAiClient.new({
      messages: messages,
      response_format: response_format,
      temperature: OpenAiClient::WORD_SUGGESTION_TEMPERATURE.presence,
    }.compact).create_completion&.dig(:content)
  end

  # Only reachable on the no-schema retry rung now, but kept for exactly that:
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

  # An unrecognised part_of_speech is dropped rather than passed through. It
  # reaches background_color_for downstream, which answers "gray" for anything
  # it does not know — so an out-of-list value does not fail loudly, it silently
  # paints a tile the wrong colour. nil means "we did not learn a POS for this
  # tile", which the caller already skips.
  def validated_part_of_speech(value)
    v = value.to_s.strip.downcase
    ColorHelper::PARTS_OF_SPEECH.include?(v) ? v : nil
  end

  # Accepts either the new "ordered_words" shape or the legacy "grid" shape
  # (back-compat with prompts/responses that still include "position").
  # Always returns a hash with "ordered_words" populated.
  #
  # Any `size` an older response still carries is read and discarded here: the
  # grid is uniform, so there is nothing for a caller to honour.
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

      {
        "word" => word,
        "frequency" => FREQUENCIES.include?(item["frequency"]) ? item["frequency"] : nil,
        "part_of_speech" => validated_part_of_speech(item["part_of_speech"]),
      }
    end

    {
      "ordered_words" => ordered,
      "personable_explanation" => payload["personable_explanation"].presence,
      "professional_explanation" => payload["professional_explanation"].presence,
    }
  end
end
