module Prompts
  # The AAC prompting kernel: who is writing, what makes a tile earn its cell,
  # and the shape the answer comes back in.
  #
  # This text was written for the admin Board Builder and lived inside
  # `Boards::AdminBuilder::Drafting`, which meant the only prompts carrying any
  # of it were the ones an admin triggers a few times a day. Every user-facing
  # word suggestion — "suggest words for this board", "add more words", the
  # scenario builder, interest pages — asked, in effect, for a topical
  # vocabulary list, which is the exact failure SYSTEM_PROMPT exists to name.
  #
  # `Drafting` still owns its own model, temperature, reasoning effort and
  # timeout: those are measured decisions about a bigger model doing a harder
  # job, and are documented in .claude-notes/board-builder.md. Only the words
  # are shared.
  module Aac
    # Sent ahead of a prompt that drafts TILES — labels plus a part of speech.
    # Kept short: it is prepended to several different prompts, and a long
    # preamble competes with the instructions that actually differ between them.
    SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a speech-language pathologist who builds AAC (Augmentative and
      Alternative Communication) grid boards for nonspeaking communicators.

      You are choosing which words earn a cell on a fixed grid a child will use
      every day — not writing a vocabulary list about a topic. A board is judged
      on what it lets someone SAY: request, refuse, comment, direct, repair. A
      board that can only name things has failed even if every word on it is
      correct.

      These hold for every request, whatever else the instructions ask for:
      - Return the EXACT tile count asked for. The grid is fixed and a partial
        last row is visible dead cells on a real board.
      - Every tile carries a part_of_speech from the list you are given. It sets
        the tile's Modified Fitzgerald Key colour, so a wrong one miscolours the
        board.
      - Respond with JSON only — no prose, no code fences, no commentary.
    PROMPT

    # The same job, for the paths that return LABELS ONLY. They feed a form or
    # an existing board rather than laying out a grid, and their callers derive
    # a part of speech separately (AacWordCategorizer), so demanding one here
    # would ask for a field nothing reads.
    WORD_LIST_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a speech-language pathologist who builds AAC (Augmentative and
      Alternative Communication) grid boards for nonspeaking communicators.

      You are choosing which words earn a cell on a fixed grid a child will use
      every day — not writing a vocabulary list about a topic. A board is judged
      on what it lets someone SAY: request, refuse, comment, direct, repair. A
      board that can only name things has failed even if every word on it is
      correct.

      These hold for every request, whatever else the instructions ask for:
      - Return the EXACT number of words asked for, with no duplicates and no
        near-duplicates.
      - Respond with JSON only — no prose, no code fences, no commentary.
    PROMPT

    # The same job, for a prompt that ADDS words to a page that already exists.
    #
    # WORD_LIST_SYSTEM_PROMPT opens with a WHOLE-BOARD judgement — "not writing
    # a vocabulary list about a topic", "a board that can only name things has
    # failed" — which is right for a caller laying out a board and wrong here.
    # A fringe page called "Food" asked for ten more words came back with `no`,
    # `stop`, `all done`, `different`, `more`, `help`, `like`, `don't like`,
    # `again`, `please`: ten out of ten core words, zero food words. Four of
    # those appear in no RULE this path sends — they came from the persona, so
    # scoping the RULES to the job (#763) could never have been enough alone.
    #
    # The instruction here is topic-OBEDIENCE, not anti-core-vocabulary, and it
    # must never name a kind of word as off-limits. The topic is whatever the
    # caller passed, and "core words" typed into the editor's prompt-override
    # box is a legitimate topic that a rule like "core words belong on another
    # page" would refuse — that box is the only way to put non-topical
    # vocabulary on a topic page, so a persona that fights it takes the escape
    # hatch away. Refusal itself is guaranteed where a board is CREATED
    # (BOARD_COVERAGE_RULES, then with_core_floor), not re-asked on every add.
    INCREMENTAL_WORD_LIST_SYSTEM_PROMPT = <<~PROMPT.freeze
      You are a speech-language pathologist who builds AAC (Augmentative and
      Alternative Communication) grid boards for nonspeaking communicators.

      You are adding words to a PAGE of a board that already exists. You are
      given its topic and the words it already holds. Your job is to extend
      that page: words that belong to its topic, that a communicator would
      really use there, and that the page does not already have. A page about
      a topic should be full of that topic — including the concrete things it
      names, which is what such a page is for.

      These hold for every request, whatever else the instructions ask for:
      - Return the EXACT number of words asked for, with no duplicates and no
        near-duplicates.
      - Every word you return must belong to the topic you are given.
      - Respond with JSON only — no prose, no code fences, no commentary.
    PROMPT

    # The word-selection rules every prompt shares, so they can't drift apart on
    # what makes a good tile.
    #
    # These are the rules that separate a board from a word list. Each one is
    # here because a draft failed on it: pages of nouns nobody can say anything
    # about, boards with no way to refuse, a preschool board that offered
    # "Tuesday" and "purple" but not "again".
    #
    # They are split into COVERAGE and CRAFT because the two answer different
    # questions and only one of them survives the trip to an incremental add.
    # Coverage asks "can this board, as a whole, do the job?" — answerable only
    # by whatever is building the whole board. Craft asks "is this a well-formed
    # tile?", which is true of any list of tiles anywhere. WORD_RULES is their
    # concatenation and is byte-for-byte what every whole-board caller already
    # sent, so splitting them changes no existing prompt.
    CORE_VOCABULARY_RULE = <<~RULES.freeze
      - Favour words that can finish many different sentences over words that
        finish one. "want", "more", "go" and "different" earn a cell on almost
        any board; "cheeseburger" earns one only on a board about lunch.
    RULES

    # Broken out on its own because it is the one coverage rule an incremental
    # add may still need. A board that cannot refuse is an autonomy failure, not
    # a style problem — so rather than dropping the ask for adds, callers put it
    # back when the board's existing tiles can't already object and redirect.
    OBJECTION_REDIRECT_RULE = <<~RULES.freeze
      - Every board needs a way to object and a way to redirect. Include at
        least one of: no, not, stop, don't like. And at least one of: again,
        different, something else, all done.
    RULES

    LABELLED_NOUN_RULE = <<~RULES.freeze
      - A noun earns a cell if the communicator can say something ABOUT it, not
        only name it. Skip nouns that exist to be labelled.
    RULES

    # Only a caller laying out a whole board can honour these.
    BOARD_COVERAGE_RULES =
      (CORE_VOCABULARY_RULE + OBJECTION_REDIRECT_RULE + LABELLED_NOUN_RULE).freeze

    # How a label is written. True of any list of tiles, whole board or not.
    WORD_CRAFT_RULES = <<~RULES.freeze
      - No closed sets as filler: no letters, digits, days of the week, months,
        or a run of colours, unless the topic is that thing.
      - Match the register to who this is for. If an age or setting is given,
        the words sound like that person's life — not a generic child's.
      - No near-duplicates ("happy" and "glad", "big" and "large"). Each tile
        costs a cell.
      - Keep each label short — 1-2 words.
      - A label is display text, not an identifier: separate words with a plain
        space, never an underscore.
    RULES

    WORD_RULES = (BOARD_COVERAGE_RULES + WORD_CRAFT_RULES).freeze

    # The two vocabularies OBJECTION_REDIRECT_RULE names, as data, so code can
    # ask whether a board already satisfies the rule.
    #
    # Deliberately NOT interpolated back into the rule text: that would rewrap
    # the prompt every whole-board caller sends, for no gain. A spec asserts
    # each entry appears in the rule instead — the same "these cannot drift
    # apart" guarantee that part_of_speech_rules gets from interpolation, with
    # none of the prompt churn.
    OBJECTION_WORDS = ["no", "not", "stop", "don't like"].freeze
    REDIRECTION_WORDS = ["again", "different", "something else", "all done"].freeze

    # Does this set of tile labels already carry a way to object AND a way to
    # redirect?
    #
    # No longer gates any prompt: incremental_word_rules used to re-add
    # OBJECTION_REDIRECT_RULE when this answered false, which is the bug
    # documented there. Kept because it is the predicate a "this board has no
    # way to refuse" nudge reads — telling the user, rather than silently
    # spending their tiles on words they did not ask for.
    #
    # Matched on word boundaries rather than string equality, so a tile labelled
    # "no thank you" counts as a way to object. Labels arrive as display text
    # (Board#current_word_list reads display_label), so casing and curly
    # apostrophes both have to be normalised away first.
    def self.can_object_or_redirect?(words)
      labels = normalise_labels(words)
      return false if labels.empty?

      mentions?(labels, OBJECTION_WORDS) && mentions?(labels, REDIRECTION_WORDS)
    end

    # The floor a WHOLE generated board is held to, in priority order.
    #
    # OBJECTION_REDIRECT_RULE is a prompt instruction, and a model that honours
    # half of it still ships: a K-3 circle-time board came back with `no`,
    # `stop`, `all done`, `different` and `something else` — and no `yes`.
    # Offering a child a way to refuse and no way to accept is an AAC modelling
    # gap an SLP reads immediately, so the ask is ALSO enforced in Ruby rather
    # than only asked for in prose.
    #
    # Order is priority order, because a small board cannot take all six:
    # yes/no lead, since an accept with no refusal (or the reverse) is the
    # specific failure this exists for.
    CORE_STARTER_WORDS = ["yes", "no", "more", "help", "stop", "I want"].freeze

    # Guarantee CORE_STARTER_WORDS on a whole-board word list.
    #
    # WHOLE-BOARD ONLY, exactly like BOARD_COVERAGE_RULES. Forcing `yes`, `no`
    # and `help` into a ten-word top-up of a fringe page called "Places" is the
    # same bug `incremental_word_rules` exists to stop, one layer down — which
    # is why `existing_words` is a parameter rather than an afterthought: a
    # board that can already say a thing is not handed it twice.
    #
    # Never grows the list past `word_count` (a generated board has a grid to
    # fit) and never spends more than HALF of it on the floor, so a small board
    # stays a board about its topic. Injected words replace the TAIL of the
    # model's list — the end it ranked least important.
    #
    # Presence is matched on word boundaries over normalised text, the same way
    # can_object_or_redirect? does, so a board carrying "no thank you" already
    # has a way to say no and one carrying "I want more" already has "more".
    def self.with_core_floor(words, word_count:, existing_words: [])
      list = Array(words).filter_map { |word| word.to_s.gsub("_", " ").strip.presence }
      count = word_count.to_i
      return list if count <= 0
      # A floor tops a list up; it does not manufacture one. The model answering
      # with nothing is a FAILURE every caller already handles — boards#words
      # 422s and GenerateBoardJob stops before building tiles — and filling that
      # emptiness with six core words would turn it into a plausible-looking
      # six-tile board instead.
      return list if list.empty?

      labels = normalise_labels(list + Array(existing_words))
      missing = CORE_STARTER_WORDS.reject { |core| mentions?(labels, [core]) }
      return list if missing.empty?

      room = [count / 2, missing.size].min
      return list if room <= 0

      missing = missing.first(room)
      list.first([count - missing.size, 0].max) + missing
    end

    # Labels arrive as display text (Board#current_word_list reads
    # display_label), so casing and curly apostrophes both have to be
    # normalised away before either side of a match is trustworthy.
    def self.normalise_labels(words)
      Array(words).filter_map do |word|
        text = word.to_s
        # unicode_normalize raises Encoding::CompatibilityError on a string that
        # is not Unicode, and on invalid bytes inside one. Labels are
        # user-authored display text and this helper is on the path of every
        # word-suggestion request, so neither is worth a 500.
        text = text.dup.force_encoding(Encoding::UTF_8) unless text.encoding == Encoding::UTF_8
        text.scrub.unicode_normalize(:nfkc).tr("‘’", "''").downcase.squish.presence
      end
    end
    private_class_method :normalise_labels

    def self.mentions?(labels, vocabulary)
      normalise_labels(vocabulary).any? do |word|
        pattern = /(?<!\w)#{Regexp.escape(word)}(?!\w)/
        labels.any? { |label| label.match?(pattern) }
      end
    end
    private_class_method :mentions?

    # Which PERSONA a word-list prompt gets: a page being topped up, or a board
    # being laid out from nothing.
    #
    # `existing_words` is the signal because it is the one the client reliably
    # has, and it tracks the `@board.new_record?` split boards#words already
    # uses to gate with_core_floor — the same request reaches this method for
    # both jobs, since a board-less /words call builds a throwaway Board. An
    # empty list is a board being drafted at /boards/new and keeps the
    # whole-board persona; words mean a real page, which gets the incremental
    # one. Swapping unconditionally would tell a from-scratch draft it is
    # extending a page that already exists.
    def self.incremental_system_prompt(existing_words: [])
      return WORD_LIST_SYSTEM_PROMPT if normalise_labels(existing_words).empty?

      INCREMENTAL_WORD_LIST_SYSTEM_PROMPT
    end

    # The rules that apply when words are being ADDED to a page that already
    # exists, rather than when a whole board is being laid out.
    #
    # Craft rules only. The coverage rules are a whole-board judgement and
    # misfire badly on an add: "skip nouns that exist to be labelled"
    # suppresses exactly the place names a board called "Places" exists for.
    #
    # The objection/redirect ask used to be re-added here when the board's own
    # tiles could not yet refuse. It is gone. WORD_CRAFT_RULES is entirely
    # formatting and negative constraints, so that ask was the only instruction
    # in the whole system message telling the model WHAT TO PICK — and being
    # uncapped ("at least one of…"), it became the entire brief: a Food page
    # asked for ten more words got ten core words and no food. Refusal is
    # guaranteed where a board is CREATED (BOARD_COVERAGE_RULES on the
    # whole-board path, then with_core_floor in Ruby), not re-asserted on every
    # top-up of a fringe page.
    def self.incremental_word_rules
      WORD_CRAFT_RULES
    end

    # Suggestions that repeat a tile the board already has.
    #
    # The prompt says not to repeat them and the model mostly obeys; this makes
    # it true, since a returned duplicate otherwise becomes a duplicate TILE.
    # Deliberately EXACT normalised equality rather than the word-boundary
    # match can_object_or_redirect? uses: a Food page holding "banana" may
    # legitimately want "banana bread", which a boundary match would drop. Also
    # de-dupes the answer against itself.
    #
    # Returning fewer words than were asked for is the right failure for a
    # suggestion list — the alternative is a top-up loop and a second billable
    # call. Validating the count is issue #751.
    def self.reject_existing(words, existing_words: [])
      seen = normalise_labels(existing_words).each_with_object({}) { |label, acc| acc[label] = true }
      Array(words).filter_map do |word|
        label = word.to_s.gsub("_", " ").strip
        next if label.blank?

        key = normalise_labels([label]).first
        next if key.nil? || seen[key]

        seen[key] = true
        label
      end
    end

    # The part-of-speech clause. The enum is interpolated from
    # ColorHelper::PARTS_OF_SPEECH rather than restated, so the prompt and the
    # colour resolver cannot disagree.
    def self.part_of_speech_rules(arrangement_rule: nil)
      <<~RULES
        - Give every tile a part_of_speech from exactly this list:
          #{ColorHelper::PARTS_OF_SPEECH.join(", ")}
        - Classify by communicative function, not strict grammar: "more", "yes" and
          "please" are social; "no", "not" and "stop" are important_function.
        #{arrangement_rule.to_s.rstrip}
      RULES
    end

    # A Structured Outputs schema for a plain list of words under `key`.
    #
    # The response key differs per call site by design — `words`,
    # `additional_words`, `next_words`, `words_phrases` are each read by their
    # own caller. Pinning the key in the schema is what stops them drifting;
    # renaming them all to one key would only move that risk into eight
    # consumer sites for no gain.
    def self.word_list_schema(key:, name: "aac_word_list")
      {
        name: name,
        strict: true,
        schema: {
          type: "object",
          additionalProperties: false,
          required: [key.to_s],
          properties: {
            key.to_s => { type: "array", items: { type: "string" } },
          },
        },
      }
    end
  end
end
