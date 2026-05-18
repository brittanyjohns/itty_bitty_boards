# frozen_string_literal: true

# Centralized parser for OpenAI chat responses that are expected to be JSON.
#
# Even with `response_format: { type: "json_object" }`, callers in this app
# historically got back content wrapped in ``` fences, with trailing commas,
# or with leading/trailing prose. Each AI-touching model used to copy-paste
# the same `gsub("```json", "").gsub("```", "").strip; valid_json?;
# transform_into_json` block. This class centralizes that.
#
# Usage:
#   parsed = AiResponseParser.parse(response[:content])
#   words  = AiResponseParser.fetch_array(response[:content], key: "words")
#
# Returns nil (never raises) on unparseable input.
class AiResponseParser
  class << self
    # Returns a Hash on success, nil on failure.
    def parse(raw)
      return nil if raw.blank?
      return raw if raw.is_a?(Hash)

      str = strip_fences(raw.to_s)
      return nil if str.blank?

      try_parse(str) ||
        try_parse(str.gsub(/,(\s*[}\]])/, '\1')) ||
        try_parse(extract_first_object(str))
    end

    # Returns the value at `key` from a parsed payload, or nil.
    # If the value is itself a JSON-encoded string, parses it.
    def fetch(raw, key:)
      payload = parse(raw)
      return nil unless payload.is_a?(Hash)

      value = payload[key.to_s] || payload[key.to_sym]
      return nil if value.nil?

      if value.is_a?(String) && looks_like_json?(value)
        parse(value) || value
      else
        value
      end
    end

    # Returns an Array at `key`. Coerces single values to a one-element array.
    # Returns [] if the key is missing or the value can't be coerced.
    def fetch_array(raw, key:)
      value = fetch(raw, key: key)
      case value
      when Array then value
      when nil then []
      else [value]
      end
    end

    private

    def strip_fences(str)
      s = str.dup
      s.sub!(/\A\s*```json\s*/i, "")
      s.sub!(/\A\s*```\s*/i, "")
      s.sub!(/```\s*\z/i, "")
      s.strip
    end

    def try_parse(str)
      return nil if str.blank?
      JSON.parse(str)
    rescue JSON::ParserError
      nil
    end

    # Finds the first {...} block in the string (best-effort) so we can
    # recover when the LLM prepends prose. Returns "" on no match.
    def extract_first_object(str)
      start = str.index("{")
      stop = str.rindex("}")
      return "" if start.nil? || stop.nil? || stop <= start
      str[start..stop]
    end

    def looks_like_json?(str)
      stripped = str.strip
      stripped.start_with?("{", "[")
    end
  end
end
