# app/services/ai_board_formatter.rb
# frozen_string_literal: true

class AiBoardFormatter
  def self.call(...) = new(...).call

  # name: Board name (for context only)
  # columns: max grid columns (Integer)
  # rows: max grid rows (Integer)
  # existing: [{ word:, size: [w,h], board_type: <optional> }, ...]
  # maintain_existing: true/false
  def initialize(name:, columns:, rows:, existing:, maintain_existing:)
    @name = name.to_s
    @columns = columns.to_i
    @rows = rows.to_i
    @existing = existing || []
    @maintain_existing = !!maintain_existing
  end

  # Returns a parsed Hash like:
  # {
  #   "grid" => [
  #     {"word"=>"I","position"=>[0,0],"part_of_speech"=>"pronoun","frequency"=>"high","size"=>[1,1]},
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
    parse_jsonish(raw)
  rescue => e
    Rails.logger.error("[AiBoardFormatter] #{e.class}: #{e.message}")
    nil
  end

  private

  def prompt
    words = @existing.map { |w| w[:word].to_s }.reject(&:blank?)

    <<~PROMPT
      You are formatting an AAC communication board layout.

      Return ONLY valid JSON. Do not include markdown, comments, or extra text.

      Goal:
      Create a clean, predictable AAC board using evidence-informed AAC layout practices:
      - Put high-frequency core words first.
      - Keep layout simple, consistent, and easy to scan.
      - Avoid random placement, gaps, and excessive rows.
      - Use stable left-to-right, top-to-bottom placement (motor planning consistency).
      - Prioritize communication usefulness over visual complexity.

      Grid constraints:
      - Max columns: #{@columns}
      - Max rows: #{@rows}
      - Coordinates are [x, y], where x starts at 0 from the left and y starts at 0 from the top.
      - Stay completely inside the grid.
      - Do not overlap cells.
      - Do not create more rows than needed.
      - Fill rows left-to-right before moving down.
      - Use a strict row-major layout (like reading text).

      Tile sizing rules:
      - Default size is [1,1].
      - Use [1,1] for almost all words.
      - Only use [2,1] for extremely important words like "I want", "help", or "stop" if space allows.
      - Do NOT use [2,2].
      - Do NOT randomly vary sizes.
      - Keep sizing consistent and predictable.

      Word ordering rules:
      1. First rows: high-frequency core words (communication starters)
      2. Next rows: common action words
      3. Next rows: descriptive words
      4. Last rows: specific or lower-frequency words

      Frequency values:
      - high
      - medium
      - low

      Important:
      - Use every provided word exactly once.
      - Do not add new words.
      - Do not remove words.
      - Do not duplicate words.
      - If there are too many words to fit, include only what fits and mention overflow in explanations.
      - Do not leave empty gaps between tiles.
      - Keep the layout compact and structured.

      Existing words:
      #{words.join(", ")}

      Expected JSON format:
      {
        "grid": [
          {
            "word": "I",
            "position": [0, 0],
            "frequency": "high",
            "size": [1, 1]
          },
          {
            "word": "banana",
            "position": [1, 0],
            "frequency": "low",
            "size": [1, 1]
          }
        ],
        "personable_explanation": "Simple one-liner explaining the layout.",
        "professional_explanation": "Simple one-liner explaining the AAC reasoning."
      }
    PROMPT
  end

  def request_openai(text)
    messages = [{ role: "user", content: [{ type: "text", text: text }] }]
    OpenAiClient.new({ messages: messages }).create_completion&.dig(:content)
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
      return JSON.parse(str)
    rescue JSON::ParserError
      # remove trailing commas: {"a":1,} or [1,2,]
      cleaned = str.gsub(/,(\s*[}\]])/, '\1')
      return JSON.parse(cleaned)
    end
  end
end
