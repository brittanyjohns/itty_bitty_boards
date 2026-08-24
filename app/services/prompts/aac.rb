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

    # The word-selection rules every prompt shares, so they can't drift apart on
    # what makes a good tile.
    #
    # These are the rules that separate a board from a word list. Each one is
    # here because a draft failed on it: pages of nouns nobody can say anything
    # about, boards with no way to refuse, a preschool board that offered
    # "Tuesday" and "purple" but not "again".
    WORD_RULES = <<~RULES.freeze
      - Favour words that can finish many different sentences over words that
        finish one. "want", "more", "go" and "different" earn a cell on almost
        any board; "cheeseburger" earns one only on a board about lunch.
      - Every board needs a way to object and a way to redirect. Include at
        least one of: no, not, stop, don't like. And at least one of: again,
        different, something else, all done.
      - A noun earns a cell if the communicator can say something ABOUT it, not
        only name it. Skip nouns that exist to be labelled.
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
