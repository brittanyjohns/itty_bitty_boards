# app/services/boards/interest_words.rb
#
# Single home for the Board Builder's interest-word normalization, shared by
# Boards::BlueprintAssembler, Boards::SeededSetCloner, and the controller
# (which persists the normalized list on the communicator and hands it to
# BuildBoardSetJob). Behavior is exactly what both services did privately:
# trim, drop blanks, dedupe (post-normalization), cap, lone "i" -> "I",
# other single chars lowercased, multi-char words kept as typed.
module Boards
  module InterestWords
    MAX_INTERESTS = 20

    module_function

    # Accepts either plain strings or { "word" => "pizza", "category" => "Food" }
    # hashes (from the categorized interest picker). Returns a flat list of
    # normalized word strings — the category info is extracted separately by
    # `extract_categories`.
    def normalize_list(list, max: MAX_INTERESTS)
      Array(list).map { |entry| normalize_word(word_from(entry)) }.reject(&:blank?).uniq.first(max)
    end

    # Builds a { normalized_word => explicit_category } map from the raw input.
    # Only entries that carried a `category` key contribute; plain strings and
    # entries without a category are absent (fall back to dictionary lookup).
    def extract_categories(list)
      Array(list).each_with_object({}) do |entry, map|
        next unless entry.is_a?(Hash) || entry.is_a?(ActionController::Parameters)

        word = normalize_word(word_from(entry))
        cat  = entry["category"].to_s.strip.presence || entry[:category].to_s.strip.presence
        map[word] = cat if word.present? && cat
      end
    end

    def normalize_word(string)
      word = string.to_s.strip
      return "" if word.blank?
      return "I" if word.casecmp("i").zero?

      word.length > 1 ? word : word.downcase
    end

    def word_from(entry)
      case entry
      when String then entry
      when Hash, ActionController::Parameters
        entry["word"].presence || entry[:word].presence || entry.to_s
      else
        entry.to_s
      end
    end
  end
end
