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
      Create an AAC communication board as a JSON object.

      Rules:
      - Start core/high-frequency words at [0,0] and group them first.
      - Group by part_of_speech (pronouns, verbs, adjectives, etc.).
      - Stay within bounds: Max columns #{@columns}, Max rows #{@rows}.
      - Size reflects frequency: high can be larger (e.g., [2,2]). Default [1,1].
      - No overlaps. Each item MUST include word, position [x,y], part_of_speech, frequency, and size [w,h].

      #{maintain_existing_text}

      Words:
      #{words.join(", ")}

      Respond ONLY with valid JSON like:
      {
        "grid": [
          {"word":"I","position":[0,0],"part_of_speech":"pronoun","frequency":"high","size":[1,1]},
          {"word":"banana","position":[1,0],"part_of_speech":"noun","frequency":"low","size":[1,1]}
        ],
        "personable_explanation": "one-liner (optional)",
        "professional_explanation": "one-liner (optional)"
      }
    PROMPT
  end

  def maintain_existing_text
    return "" unless @maintain_existing && @existing.present?

    # Keep this short so it doesn't drown the prompt
    pairs = @existing.first(40).map do |w|
      size = Array(w[:size]).presence || [1, 1]
      "#{w[:word]}=>#{size.join("x")}"
    end
    "Try to keep current sizes where sensible: #{pairs.join(", ")}"
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
