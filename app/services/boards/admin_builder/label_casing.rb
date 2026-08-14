module Boards
  module AdminBuilder
    # What a drafted label looks like by the time it reaches the form: cleaned of
    # identifier artifacts, and folded to the lowercase AAC default unless the
    # capital was meant.
    #
    # The three drafters each grew their own `sanitize_label`, and none of them
    # touched casing at all — so the model's Title Case ("Food", "All Done") went
    # straight into the textarea an admin reads, and from there into the plan.
    # `Image#set_label` folds a plain leading capital, but only when the Image is
    # NEW, and never for a tile whose plan carries an explicit `display_label` —
    # so by the time the fold could have happened, the capital had usually
    # already won.
    #
    # Casing itself is NOT decided here. `Labels::CaseNormalizer` is the single
    # authority for that and already knows the hard parts — "iPad", "TV",
    # "McDonald's" and "HELP" survive, a standalone "i" is upcased, and the
    # judgement is per word. This module only decides WHICH labels are the
    # normalizer's business.
    module LabelCasing
      module_function

      # Handed to every drafter's prompt so the three can't drift apart. Asking
      # for lowercase up front matters as much as folding afterwards: the model
      # picks better words when it isn't also composing a title.
      PROMPT_RULE = <<~RULE.freeze
        - Write every label in LOWERCASE. These are word tiles, not sentences or
          titles — "apple", not "Apple"; "all done", not "All Done".
        - The only exceptions are proper nouns (a person, a place, a brand) and
          words with a deliberate internal capital like "iPad" or "TV". Set
          "proper_noun": true on any tile whose capital is deliberate, and leave
          it off every other tile.
      RULE

      # The model occasionally answers a multi-word label snake_cased, like an
      # identifier rather than the tile text it's meant to be — underscores have
      # no legitimate place in display text, so they're folded to spaces rather
      # than left for the admin to notice and retype. Distinct from
      # `Keys.normalize`: a page "key" is meant to be underscored.
      def sanitize(raw)
        raw.to_s.strip.tr("_", " ").squeeze(" ").strip
      end

      # `door` is a tile with a `links_to` — a folder tile or a way back. A
      # category tile's label is authored, not defaulted ("Food", "Play"), and an
      # AAC board leans on that capital to separate a page you open from a word
      # you speak. `FolderTiles` already pins `display_label` on the doors it
      # writes for exactly this reason; keeping model-written doors unfolded is
      # what makes the two agree.
      #
      # `proper_noun` is the model's own claim, and it is only honoured when the
      # label actually carries a capital — an over-eager flag on "apple" would
      # otherwise be a silent no-op that looks like a rule.
      def apply(label, part_of_speech: nil, proper_noun: false, door: false)
        text = label.to_s
        return text if door
        return text if proper_noun && text.match?(/\p{Upper}/)

        Labels::CaseNormalizer.normalize(text, part_of_speech: part_of_speech)
      end

      # Reads the model's flag off a raw tile hash. Tolerant of the string
      # "true", which JSON mode returns often enough to be worth handling.
      def proper_noun?(tile)
        value = tile["proper_noun"]
        value == true || value.to_s.strip.downcase == "true"
      end
    end
  end
end
