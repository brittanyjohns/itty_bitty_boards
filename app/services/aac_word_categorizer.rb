# app/services/aac_word_categorizer.rb
# Purpose: Categorize a word/phrase into Modified Fitzgerald Key categories for AAC color coding.

class AacWordCategorizer
  PARTS_OF_SPEECH = %w[
    adjective
    verb
    pronoun
    noun
    conjunction
    preposition
    social
    question
    adverb
    important_function
    determiner
    default
  ].freeze

  # High-confidence overrides (no API call, consistent, cheap)
  # NOTE: Put AAC-functional classifications here (not traditional grammar).
  OVERRIDES = {
    # Social / polite / quick interaction
    "hi" => "social",
    "bye" => "social",
    "please" => "social",
    "thank you" => "social",
    "excuse me" => "social",
    "sorry" => "social",

    # Requests / interaction words (AAC convention)
    "more" => "social",
    "again" => "social",
    "finished" => "social",
    "all done" => "social",
    "yes" => "social",

    # Important function / negation / emergency
    "no" => "important_function",
    "not" => "important_function",
    "don't" => "important_function",
    "dont" => "important_function",
    "can't" => "important_function",
    "cant" => "important_function",
    "won't" => "important_function",
    "wont" => "important_function",
    "help!" => "important_function",
    "stop!" => "important_function",

    # Determiners / articles / deixis
    "this" => "determiner",
    "that" => "determiner",
    "here" => "determiner",
    "there" => "determiner",
    "a" => "determiner",
    "an" => "determiner",
    "the" => "determiner",
    "these" => "determiner",
    "those" => "determiner",

    # Questions
    "what" => "question",
    "where" => "question",
    "who" => "question",
    "when" => "question",
    "why" => "question",
    "how" => "question"
  }.freeze

  # Keep prompt small (cost) but strict (consistency)
  SYSTEM_PROMPT = <<~TEXT.freeze
    You categorize AAC words/phrases into exactly ONE category.
    Use Modified Fitzgerald Key functional AAC meaning (not traditional grammar).

    Output MUST be valid JSON with EXACTLY this schema:
    {"part_of_speech":"adjective|verb|pronoun|noun|conjunction|preposition|social|question|adverb|important_function|determiner|default"}

    No other keys. No explanations. If uncertain, use "default".
    If input contains multiple words, categorize the whole phrase as ONE category.
  TEXT

  USER_PROMPT_TEMPLATE = <<~TEXT.freeze
    Word or phrase: "%<input>s"
    Return JSON only.
  TEXT

  # ---- Public API ----
  # Returns a String category from PARTS_OF_SPEECH (always valid).
  def self.categorize(input, model: "gpt-4o-mini", cache_ttl: 30.days)
    normalized = normalize(input)
    return "default" if normalized.blank?

    # Local override first (free + consistent)
    if (override = OVERRIDES[normalized])
      return override
    end

    # Cache to avoid repeated API calls
    cache_key = "aac_pos:v1:#{Digest::SHA256.hexdigest(normalized)}"
    cached = Rails.cache.read(cache_key)
    return cached if cached.present? && PARTS_OF_SPEECH.include?(cached)

    # Call model
    response_text = call_llm(normalized, model: model)

    # Parse + validate
    pos = extract_pos(response_text)

    Rails.cache.write(cache_key, pos, expires_in: cache_ttl)
    pos
  end

  # ---- Helpers ----

  def self.normalize(input)
    input.to_s.downcase.strip.gsub(/\s+/, " ")
  end

  def self.call_llm(normalized, model:)
    messages = [
      { role: "system", content: SYSTEM_PROMPT },
      { role: "user", content: format(USER_PROMPT_TEMPLATE, input: normalized) }
    ]

    # IMPORTANT: Replace this with your actual LLM call.
    # You said you already have create_chat — adjust signature as needed.
    #
    # Example expected: create_chat(model: model, messages: messages) -> string content
    OpenAiClient.new(model: model, messages: messages).create_chat
  rescue => e
    Rails.logger.error("[AacWordCategorizer] LLM call failed: #{e.class} #{e.message}")
    nil
  end

  def self.extract_pos(response)
    return "default" if response.blank?

    content_text = extract_content_text(response)

    json = safe_json_parse(content_text)

    pos = json.is_a?(Hash) ? json["part_of_speech"] : nil
    return pos if PARTS_OF_SPEECH.include?(pos)

    "default"
    end

    def self.extract_content_text(response)
    # If the client already returns the assistant content as a string
    return response if response.is_a?(String)

    # If it returns a Ruby hash (symbol keys)
    if response.is_a?(Hash)
        # Common: {:role=>"assistant", :content=>"..."}
        if response.key?(:content)
        return response[:content].to_s
        end

        # Also handle string-key variants
        if response.key?("content")
        return response["content"].to_s
        end

        # If your client later returns full OpenAI response objects,
        # try a few common shapes:
        if response.dig("choices", 0, "message", "content")
        return response.dig("choices", 0, "message", "content").to_s
        end
        if response.dig(:choices, 0, :message, :content)
        return response.dig(:choices, 0, :message, :content).to_s
        end
    end

    # Last resort: stringify
    response.to_s
    end


  # Handles cases where the model wraps JSON in text or code fences.
  def self.safe_json_parse(text)
    stripped = text.to_s.strip

    # Remove ```json fences if present
    stripped = stripped.gsub(/\A```(?:json)?\s*/i, "").gsub(/\s*```\z/, "")

    # Try direct parse
    JSON.parse(stripped)
  rescue JSON::ParserError
    # Try to extract first JSON object from the string
    begin
      match = stripped.match(/\{.*\}/m)
      match ? JSON.parse(match[0]) : nil
    rescue JSON::ParserError
      nil
    end
  end
end
