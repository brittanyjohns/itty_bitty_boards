# frozen_string_literal: true

# Centralized parser for OpenAI chat responses that are expected to be JSON.
#
# `OpenAiClient#create_chat` sets `response_format: { type: "json_object" }`,
# but the model still occasionally returns content wrapped in ```json fences,
# with trailing commas, or with surrounding prose. The Board word-suggestion
# methods used to each copy the same 8-line "strip fences → valid_json? →
# transform_into_json → parse → fetch key" block. This class centralizes that.
#
# Usage:
#   AiResponseParser.fetch_words(response[:content], key: "words")
#   # => Array<String> on success, nil on failure
#
# Returns nil (never raises) on unparseable input so callers can render a
# generic error.
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

    # Pulls an Array<String> from a parsed payload at the given key.
    # Returns nil if the payload is unparseable or the key is missing —
    # callers treat nil as "no suggestions, render an error".
    #
    # Filters non-string entries and blanks; does NOT lowercase or dedup
    # (callers handle that, since some preserve casing for proper nouns).
    def fetch_words(raw, key:)
      payload = parse(raw)
      return nil unless payload.is_a?(Hash)

      value = payload[key.to_s] || payload[key.to_sym]
      return nil if value.nil?

      Array(value).filter_map do |entry|
        next unless entry.is_a?(String)
        stripped = entry.strip
        stripped unless stripped.empty?
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
  end
end
