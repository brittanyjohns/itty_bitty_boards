# app/services/boards/interest_categories.rb
#
# Maps an interest word -> the category folder it belongs in, for the hybrid
# Board Builder wizard (see Boards::BlueprintAssembler).
#
# Routing is keyed by the *folder label* used in the starter templates
# (Boards::StarterBlueprints), e.g. "Food" / "Feelings" / "Bathroom" / "Play".
# An interest only ever routes into a folder the chosen template actually has —
# the assembler checks folder presence and falls anything else through to the
# single "My Favorites" catch-all. So a word mapped to "Bathroom" still lands in
# Favorites on a template (like HOME) that has no Bathroom folder.
#
# The lexicon is deliberately small and hand-curated for v1; extend the lists as
# real usage shows what kids actually ask for. Adding a brand-new category here
# is inert until a template grows a folder with the matching label.
module Boards
  module InterestCategories
    # Folder label => the words that route into it. Words are matched
    # case-insensitively (stored lowercase). Keep words in exactly one list so
    # the reverse index below is unambiguous.
    KEYWORDS = {
      "Food" => %w[
        apple banana orange grapes grape strawberry strawberries watermelon
        water juice milk snack snacks cookie cookies pizza cracker crackers
        cheese yogurt cereal bread pasta noodles chicken rice carrot candy
        chocolate icecream sandwich soup egg eggs fruit drink hungry eat
      ],
      "Feelings" => %w[
        happy sad tired angry mad scared silly calm frustrated nervous proud
        shy sleepy sick hurt love worried surprised bored lonely grumpy excited
        cranky frightened upset
      ],
      "Bathroom" => %w[
        toilet potty wash soap towel bath shower brush teeth flush wipe diaper
        pee poop sink handwashing
      ],
      "Play" => %w[
        train trains dinosaur dinosaurs ball blocks block painting paint cars
        car music books book puzzle puzzles doll dolls lego legos bike swing
        slide park game games drawing draw dance dancing sing singing bubbles
        animals truck trucks robot robots superhero princess art color colors
        coloring outside run toys
      ],
    }.freeze

    # Reverse index word -> category, built once at load for O(1) lookup.
    WORD_TO_CATEGORY = KEYWORDS.each_with_object({}) do |(category, words), map|
      words.each { |word| map[word] = category }
    end.freeze

    module_function

    # The category folder label for an interest word, or nil if it has no home.
    def category_for(word)
      WORD_TO_CATEGORY[word.to_s.strip.downcase]
    end

    # All category labels the lexicon knows about.
    def categories
      KEYWORDS.keys
    end
  end
end
