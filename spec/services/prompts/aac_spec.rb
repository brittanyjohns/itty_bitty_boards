require "rails_helper"

RSpec.describe Prompts::Aac do
  # These strings are the product's actual AAC expertise. Specs elsewhere assert
  # that a prompt *includes* WORD_RULES; nothing asserted the rules themselves
  # survive an edit, so they could be deleted with CI staying green.
  describe "WORD_RULES" do
    subject(:rules) { described_class::WORD_RULES }

    it "requires a way to object and a way to redirect" do
      expect(rules).to include("a way to object and a way to redirect")
      expect(rules).to include("no, not, stop, don't like")
      expect(rules).to match(/again,\s+different, something else, all done/)
    end

    it "prefers words that finish many sentences over topic nouns" do
      expect(rules).to include("finish many different sentences")
    end

    it "keeps closed sets off a board unless they are the topic" do
      expect(rules).to include("No closed sets as filler")
    end

    it "rules out near-duplicates" do
      expect(rules).to include("No near-duplicates")
    end

    it "requires a plain space in a label, never an underscore" do
      expect(rules).to include("never an underscore")
    end
  end

  # The split into coverage + craft exists so an incremental add can take the
  # craft half without the whole-board half. It is only safe because WORD_RULES
  # still composes to exactly the text every whole-board caller already sent.
  describe "the coverage / craft split" do
    it "composes WORD_RULES out of the two halves, in order" do
      expect(described_class::WORD_RULES)
        .to eq(described_class::BOARD_COVERAGE_RULES + described_class::WORD_CRAFT_RULES)
    end

    it "puts the whole-board judgements in the coverage half" do
      coverage = described_class::BOARD_COVERAGE_RULES

      expect(coverage).to include("finish many different sentences")
      expect(coverage).to include("a way to object and a way to redirect")
      expect(coverage).to include("Skip nouns that exist to be labelled")
    end

    it "puts the how-a-label-is-written rules in the craft half" do
      craft = described_class::WORD_CRAFT_RULES

      expect(craft).to include("No closed sets as filler")
      expect(craft).to include("Match the register")
      expect(craft).to include("No near-duplicates")
      expect(craft).to include("Keep each label short")
      expect(craft).to include("never an underscore")
    end

    # The craft half travels to prompts that are NOT laying out a whole board,
    # where a coverage rule would misfire — "skip nouns that exist to be
    # labelled" suppresses exactly the place names a Places board is for.
    it "keeps every coverage judgement out of the craft half" do
      craft = described_class::WORD_CRAFT_RULES

      expect(craft).not_to include("a way to object and a way to redirect")
      expect(craft).not_to include("Skip nouns that exist to be labelled")
      expect(craft).not_to include("finish many different sentences")
    end
  end

  # The detector lists are not interpolated into the rule text (that would
  # rewrap every whole-board caller's prompt), so this is what stops the two
  # drifting apart instead.
  describe "the objection / redirection vocabularies" do
    it "names every objection word the rule asks the model for" do
      described_class::OBJECTION_WORDS.each do |word|
        expect(described_class::OBJECTION_REDIRECT_RULE).to include(word)
      end
    end

    it "names every redirection word the rule asks the model for" do
      described_class::REDIRECTION_WORDS.each do |word|
        expect(described_class::OBJECTION_REDIRECT_RULE).to include(word)
      end
    end
  end

  describe ".can_object_or_redirect?" do
    it "is true when the board has both a way to object and a way to redirect" do
      expect(described_class.can_object_or_redirect?(["want", "stop", "all done"])).to be(true)
    end

    it "is false when the board can object but not redirect" do
      expect(described_class.can_object_or_redirect?(["want", "stop", "more"])).to be(false)
    end

    it "is false when the board can redirect but not object" do
      expect(described_class.can_object_or_redirect?(["want", "again", "more"])).to be(false)
    end

    # A fringe page — the case that started this. Nothing on it refuses.
    it "is false for a page of place names" do
      expect(described_class.can_object_or_redirect?(%w[store kitchen bedroom car zoo dentist])).to be(false)
    end

    it "is false for an empty or blank board" do
      expect(described_class.can_object_or_redirect?([])).to be(false)
      expect(described_class.can_object_or_redirect?(nil)).to be(false)
      expect(described_class.can_object_or_redirect?(["", "  "])).to be(false)
    end

    # Labels arrive as display text, so casing and curly apostrophes are noise.
    it "ignores casing and curly apostrophes" do
      expect(described_class.can_object_or_redirect?(["Stop", "All Done"])).to be(true)
      expect(described_class.can_object_or_redirect?(["don\u2019t like", "again"])).to be(true)
    end

    # Matched on word boundaries, so a multi-word tile still counts...
    it "finds the word inside a longer label" do
      expect(described_class.can_object_or_redirect?(["no thank you", "something else"])).to be(true)
    end

    # ...but a word that merely starts the same does not.
    it "does not match a word that only shares a prefix" do
      expect(described_class.can_object_or_redirect?(%w[notebook against])).to be(false)
      expect(described_class.can_object_or_redirect?(%w[nothing againstall])).to be(false)
    end
  end

  describe ".incremental_word_rules" do
    it "always carries the craft rules" do
      expect(described_class.incremental_word_rules).to include(described_class::WORD_CRAFT_RULES)
    end

    # The ask used to be re-added when the board's own tiles could not refuse.
    # WORD_CRAFT_RULES is entirely formatting and negative constraints, so it
    # was the only instruction telling the model WHAT TO PICK — and being
    # uncapped, it became the whole brief: a Food page asked for ten more words
    # got ten core words and no food. Refusal is guaranteed where a board is
    # CREATED, not re-asserted on every top-up.
    it "never spends an add's budget on the objection ask" do
      rules = described_class.incremental_word_rules

      expect(rules).not_to include("a way to object and a way to redirect")
      expect(rules).not_to include("something else")
      expect(rules).not_to include(described_class::OBJECTION_REDIRECT_RULE)
    end

    # A fringe page names things on purpose; the core board carries refusal.
    it "never suppresses nouns" do
      expect(described_class.incremental_word_rules)
        .not_to include("Skip nouns that exist to be labelled")
    end

    it "never carries the full whole-board coverage set" do
      expect(described_class.incremental_word_rules)
        .not_to include(described_class::BOARD_COVERAGE_RULES)
    end
  end

  describe "INCREMENTAL_WORD_LIST_SYSTEM_PROMPT" do
    let(:persona) { described_class::INCREMENTAL_WORD_LIST_SYSTEM_PROMPT }

    it "keeps the SLP framing" do
      expect(persona).to include("speech-language pathologist")
      expect(persona).to include("nonspeaking communicators")
    end

    # The judgement that produced `more`, `help`, `like` and `please` on a Food
    # page — four words that appear in no RULE this path sends.
    it "drops the whole-board judgement that a naming board has failed" do
      expect(persona).not_to include("board that can only name things has failed")
      expect(persona).not_to include("not writing a vocabulary list about a topic")
    end

    it "says a topic page names things on purpose" do
      expect(persona).to include("full of that topic")
    end

    it "keeps the count and format guarantees verbatim" do
      expect(persona).to include("Return the EXACT number of words asked for, with no duplicates and no")
      expect(persona).to include("Respond with JSON only — no prose, no code fences, no commentary.")
    end

    # The prompt-override box is the only way to put non-topical vocabulary on a
    # topic page. A persona that names core words as off-limits would refuse
    # "core words" typed into it, so the instruction is topic-OBEDIENCE only.
    it "names no kind of word as off-limits, so an override can still steer it" do
      expect(persona).to include("must belong to the topic you are given")
      expect(persona).not_to match(/core words?.*(another|somebody else's|different) page/i)
      expect(persona).not_to include("Core words the whole board shares")
    end
  end

  describe ".incremental_system_prompt" do
    # A board-less /words request builds a throwaway Board and reaches this same
    # path, so the persona is SELECTED rather than swapped.
    it "keeps the whole-board persona for a board being drafted from nothing" do
      [[], nil, ["", "  "]].each do |words|
        expect(described_class.incremental_system_prompt(existing_words: words))
          .to eq(described_class::WORD_LIST_SYSTEM_PROMPT)
      end
    end

    it "uses the incremental persona for a page that already holds words" do
      expect(described_class.incremental_system_prompt(existing_words: %w[banana cracker egg]))
        .to eq(described_class::INCREMENTAL_WORD_LIST_SYSTEM_PROMPT)
    end
  end

  describe ".reject_existing" do
    it "drops a word the board already has, whatever its casing" do
      expect(described_class.reject_existing(%w[Banana toast], existing_words: %w[banana]))
        .to eq(%w[toast])
    end

    it "folds curly apostrophes on both sides" do
      expect(described_class.reject_existing(["don't like"], existing_words: ["don\u2019t like"]))
        .to eq([])
    end

    # Exact equality, not the word-boundary match the floors use: a Food page
    # holding "banana" may legitimately want "banana bread".
    it "keeps a longer phrase that merely contains an existing word" do
      expect(described_class.reject_existing(["banana bread"], existing_words: %w[banana]))
        .to eq(["banana bread"])
    end

    it "de-dupes the answer against itself, keeping the first spelling" do
      expect(described_class.reject_existing(%w[Toast toast jam], existing_words: []))
        .to eq(%w[Toast jam])
    end

    it "preserves order and normalises underscores" do
      expect(described_class.reject_existing(["ice_cream", "pie"], existing_words: []))
        .to eq(["ice cream", "pie"])
    end

    it "answers an empty list for nothing" do
      expect(described_class.reject_existing(nil, existing_words: %w[banana])).to eq([])
      expect(described_class.reject_existing(["", "  "], existing_words: [])).to eq([])
    end
  end

  describe "SYSTEM_PROMPT" do
    it "frames the job as what a board lets someone say, not what it names" do
      expect(described_class::SYSTEM_PROMPT).to match(/request, refuse, comment, direct, repair/)
      expect(described_class::SYSTEM_PROMPT).to include("board that can only name things has failed")
    end
  end

  describe "WORD_LIST_SYSTEM_PROMPT" do
    # The whole-board judgement stays HERE. Three callers still lay out a whole
    # board through this persona — ScenariosController, the social-story path,
    # and WORD_SUGGESTION_SYSTEM_PROMPT — so the incremental fix had to add a
    # persona beside it, never soften this one.
    it "keeps the whole-board judgement for the callers that lay out a board" do
      expect(described_class::WORD_LIST_SYSTEM_PROMPT)
        .to include("board that can only name things has failed")
      expect(described_class::WORD_LIST_SYSTEM_PROMPT)
        .to include("not writing a vocabulary list about a topic")
    end
  end

  describe ".part_of_speech_rules" do
    it "interpolates the canonical vocabulary rather than restating one" do
      rules = described_class.part_of_speech_rules

      ColorHelper::PARTS_OF_SPEECH.each { |pos| expect(rules).to include(pos) }
    end

    it "classifies by communicative function rather than grammar" do
      expect(described_class.part_of_speech_rules).to include("communicative function, not strict grammar")
    end

    it "appends an arrangement rule when one is given" do
      expect(described_class.part_of_speech_rules(arrangement_rule: "SORT LIKE THIS"))
        .to include("SORT LIKE THIS")
    end
  end

  describe ".word_list_schema" do
    subject(:schema) { described_class.word_list_schema(key: "additional_words") }

    # Strict mode is what makes the response key a guarantee rather than a hope.
    it "pins the response key the caller reads" do
      expect(schema[:strict]).to be(true)
      expect(schema[:schema][:required]).to eq(["additional_words"])
      expect(schema[:schema][:properties]).to have_key("additional_words")
    end

    it "forbids extra keys" do
      expect(schema[:schema][:additionalProperties]).to be(false)
    end

    it "asks for an array of strings" do
      expect(schema[:schema][:properties]["additional_words"])
        .to eq({ type: "array", items: { type: "string" } })
    end
  end

  # The extraction must be behaviour-preserving for the admin Board Builder,
  # whose prompt text, temperature and reasoning effort are measured decisions.
  describe "the AdminBuilder aliases" do
    it "keeps Drafting's constants pointing at the shared text" do
      expect(Boards::AdminBuilder::Drafting::SYSTEM_PROMPT).to eq(described_class::SYSTEM_PROMPT)
      expect(Boards::AdminBuilder::Drafting::WORD_RULES).to eq(described_class::WORD_RULES)
    end

    it "still splices the tile-arrangement rule into Drafting's POS clause" do
      expect(Boards::AdminBuilder::Drafting.part_of_speech_rules)
        .to include(Boards::AdminBuilder::TileArrangement::PROMPT_RULE.rstrip)
    end
  end
  # A K-3 circle-time board came back with `no`, `stop`, `all done`, `different`
  # and `something else` — and no `yes`. OBJECTION_REDIRECT_RULE asks for a way
  # to refuse and a way to redirect, and a model that honours exactly that much
  # still ships a board that can decline and cannot accept, which an SLP reads
  # immediately as "this tool doesn't know AAC". So the ask is enforced after
  # the fact as well as asked for in prose.
  describe ".with_core_floor" do
    it "adds every missing core word to a board that has room" do
      result = described_class.with_core_floor(%w[hello sunny rainy cloudy], word_count: 24)

      expect(result).to include(*described_class::CORE_STARTER_WORDS)
      expect(result.first(4)).to eq(%w[hello sunny rainy cloudy])
    end

    # The reported board: it could say no and not yes.
    it "adds yes to a board that can already refuse" do
      words = ["hello", "I feel happy", "no", "stop", "all done", "different"]

      result = described_class.with_core_floor(words, word_count: 24)

      expect(result).to include("yes")
    end

    it "leaves a list that already covers the floor exactly as it found it" do
      words = ["yes", "no", "more", "help", "stop", "I want"]

      expect(described_class.with_core_floor(words, word_count: 24)).to eq(words)
    end

    # Matched on word boundaries over normalised text, the same way
    # can_object_or_redirect? matches, so a board is not handed a word it has.
    it "counts a core word carried inside a longer label" do
      words = ["no thank you", "I want more", "yes please", "help me", "stop it", "song"]

      expect(described_class.with_core_floor(words, word_count: 24)).to eq(words)
    end

    it "counts a core word the board already has, given as existing_words" do
      result = described_class.with_core_floor(%w[sunny rainy], word_count: 24, existing_words: %w[yes no])

      expect(result).not_to include("yes")
      expect(result).not_to include("no")
      expect(result).to include("more")
    end

    it "never grows the list past the word count it was asked for" do
      result = described_class.with_core_floor(%w[a b c d e f g h], word_count: 8)

      expect(result.size).to eq(8)
      expect(result).to include("yes", "no", "more", "help")
    end

    # A small board that spent every cell on the floor would stop being a board
    # about its topic, so the floor takes at most half and leads with yes/no —
    # the pair this exists for.
    it "spends at most half a small board on the floor, highest priority first" do
      result = described_class.with_core_floor(%w[apple banana cherry date], word_count: 4)

      expect(result).to eq(%w[apple banana yes no])
    end

    # The model answering with nothing is a failure the callers already handle;
    # filling it with six core words would turn that into a plausible-looking
    # six-tile board nobody asked for.
    it "does not manufacture a board out of an empty answer" do
      expect(described_class.with_core_floor([], word_count: 24)).to eq([])
      expect(described_class.with_core_floor(nil, word_count: 24)).to eq([])
    end

    it "does nothing when it is given no room at all" do
      expect(described_class.with_core_floor(%w[a b], word_count: 0)).to eq(%w[a b])
    end
  end
end
