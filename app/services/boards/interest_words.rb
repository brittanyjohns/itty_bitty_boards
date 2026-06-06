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
    MAX_INTERESTS = 12

    module_function

    def normalize_list(list, max: MAX_INTERESTS)
      Array(list).map { |s| normalize_word(s) }.reject(&:blank?).uniq.first(max)
    end

    def normalize_word(string)
      word = string.to_s.strip
      return "" if word.blank?
      return "I" if word.casecmp("i").zero?

      word.length > 1 ? word : word.downcase
    end
  end
end
