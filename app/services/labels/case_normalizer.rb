module Labels
  # Casing rules for tile text (`display_label`).
  #
  # `Image#label` is a lowercase matching key, not display text. Creation paths
  # that hand us a Title Cased word list produce Title Cased tiles; paths that
  # fall through to the raw `label` produce lowercase ones — so one board ends
  # up rendering "Higher" next to "swing". That reads as a defect in print,
  # where these boards become physical signs.
  #
  # The default is lowercase (the AAC core-vocabulary convention), not Title
  # Case — so the fix for the inconsistency above is "Higher" settling down to
  # "higher", not "swing" climbing up to "Swing".
  #
  # This normalizes the **defaulted** case only. Callers that explicitly supply
  # a `display_label` never route through here — their casing wins.
  #
  # "Deliberate casing" is judged PER WORD, and means a capital the author could
  # only have typed on purpose: one past the first letter ("iPad", "TV",
  # "McDonald's", "HELP"). Those words are returned untouched.
  #
  # A plain LEADING capital is not evidence of intent — it is what a word-list
  # line, an LLM's JSON label, or ordinary typing produces — so it is folded
  # down to the lowercase default. Treating it as deliberate is what made this
  # service a no-op on the input it exists to fix: every tile that arrived
  # "Fun"/"Giraffe"/"Go" bailed out and stayed Title Cased, so a board rendered
  # "Fun" next to "spot" (#583 only ever worked on already-lowercase input).
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

      english = english?(language)
      if english && part_of_speech.to_s != PHRASE_PART_OF_SPEECH
        lowercase_case(text)
      else
        sentence_case(text, english: english)
      end
    end

    # A capital PAST the first letter is one the author could only have typed on
    # purpose — "iPad", "TV", "McDonald's", "HELP". A naive titleize would wreck
    # all of those, and an exception list would have to be maintained forever.
    # Leave such a word alone.
    #
    # Judged per word, so one styled word doesn't exempt the whole label: "My
    # iPad" folds to "my iPad" rather than staying Title Cased throughout.
    def deliberate_casing?(word)
      word.to_s.sub(/\A\P{Alpha}*\p{Alpha}/, "").match?(/\p{Upper}/)
    end

    # Title Case is an English convention; Spanish wants "Todo listo", not
    # "Todo Listo".
    def english?(language)
      lang = language.to_s.strip.downcase
      lang.empty? || lang == "en" || lang.start_with?("en-", "en_")
    end

    # AAC core-vocabulary convention: tiles stay lowercase, not Title Case or
    # sentence-initial capitals — most single/multi-word boards (LAMP, Unity,
    # Word Power, PrAACtical AAC) present core words lowercase throughout. The
    # pronoun "I" is the one grammar rule that survives regardless of style or
    # position in the tile text.
    def lowercase_case(text)
      transform_words(text) do |word|
        if word.match?(STANDALONE_I)
          upcase_first(word)
        else
          fold_first(word)
        end
      end
    end

    # First word capitalized, the rest folded to the lowercase default — except
    # a standalone "i", which stays capitalized wherever it lands, and a word
    # whose casing was deliberate, which is never touched.
    def sentence_case(text, english: true)
      first = true
      transform_words(text) do |word|
        if first
          first = false
          # "iPad is broken" must not become "IPad is broken".
          deliberate_casing?(word) ? word : upcase_first(word)
        elsif english && word.match?(STANDALONE_I)
          upcase_first(word)
        else
          fold_first(word)
        end
      end
    end

    # Downcase an accidental leading capital, leaving a deliberately cased word
    # ("iPad", "TV") exactly as authored.
    def fold_first(word)
      return word if deliberate_casing?(word)

      word.sub(/\p{Alpha}/) { |char| char.downcase }
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
