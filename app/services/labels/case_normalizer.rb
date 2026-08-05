module Labels
  # Casing rules for tile text (`display_label`).
  #
  # `Image#label` is a lowercase matching key, not display text. Creation paths
  # that hand us a Title Cased word list produce Title Cased tiles; paths that
  # fall through to the raw `label` produce lowercase ones — so one board ends
  # up rendering "Higher" next to "swing". That reads as a defect in print,
  # where these boards become physical signs.
  #
  # This normalizes the **defaulted** case only. Callers that explicitly supply
  # a `display_label` never route through here — their casing wins.
  #
  # The transform only ever upcases the first letter of a word. It never
  # downcases, so nothing that slips past `deliberate_casing?` can be mangled.
  module CaseNormalizer
    # Whole-utterance tiles (gestalt / GLP) read as sentences, not headlines.
    PHRASE_PART_OF_SPEECH = "phrase".freeze

    # A word whose leading alphabetic run is exactly "i" — matches "i", "i'll",
    # "i," but not "in" or "is".
    STANDALONE_I = /\A\P{Alpha}*i(?!\p{Alpha})/i

    module_function

    # @param text [String, nil] the defaulted label
    # @param language [String, nil] the tile's authored language
    # @param part_of_speech [String, nil] the tile's resolved part of speech
    def normalize(text, language: nil, part_of_speech: nil)
      text = text.to_s
      return text if text.strip.empty?
      return text if deliberate_casing?(text)

      english = english?(language)
      if english && part_of_speech.to_s != PHRASE_PART_OF_SPEECH
        title_case(text)
      else
        sentence_case(text, english: english)
      end
    end

    # Any existing uppercase letter means the text was cased on purpose —
    # "iPad", "TV", "McDonald's". A naive titleize would wreck all three, and an
    # exception list would have to be maintained forever. Leave it alone.
    def deliberate_casing?(text)
      text.to_s.match?(/\p{Upper}/)
    end

    # Title Case is an English convention; Spanish wants "Todo listo", not
    # "Todo Listo".
    def english?(language)
      lang = language.to_s.strip.downcase
      lang.empty? || lang == "en" || lang.start_with?("en-", "en_")
    end

    def title_case(text)
      transform_words(text) { |word| upcase_first(word) }
    end

    # First word capitalized, the rest left as authored — except a standalone
    # "i", which stays capitalized wherever it lands.
    def sentence_case(text, english: true)
      first = true
      transform_words(text) do |word|
        if first
          first = false
          upcase_first(word)
        elsif english && word.match?(STANDALONE_I)
          upcase_first(word)
        else
          word
        end
      end
    end

    # Upcase the first alphabetic character, leaving leading punctuation and
    # every interior character untouched.
    def upcase_first(word)
      word.sub(/\p{Alpha}/) { |char| char.upcase }
    end

    # Split on whitespace, keeping the separators so the original spacing
    # survives the round trip.
    def transform_words(text)
      text.split(/(\s+)/).map { |chunk| chunk.match?(/\S/) ? yield(chunk) : chunk }.join
    end
  end
end
