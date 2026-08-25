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
      expect(described_class.incremental_word_rules(existing_words: []))
        .to include(described_class::WORD_CRAFT_RULES)
      expect(described_class.incremental_word_rules(existing_words: ["stop", "all done"]))
        .to include(described_class::WORD_CRAFT_RULES)
    end

    # The rule is an autonomy requirement, so it is re-added rather than dropped
    # when the board genuinely cannot refuse yet.
    it "asks for a way to object when the board has none" do
      rules = described_class.incremental_word_rules(existing_words: %w[store kitchen zoo])

      expect(rules).to include("a way to object and a way to redirect")
    end

    # ...and is not spent on a board that already has all four words, which is
    # what filled a Places board with "again" / "different" / "all done".
    it "does not ask again when the board can already object and redirect" do
      rules = described_class.incremental_word_rules(existing_words: ["go", "stop", "all done"])

      expect(rules).not_to include("a way to object and a way to redirect")
      expect(rules).not_to include("something else")
    end

    # A fringe page names things on purpose; the core board carries refusal.
    it "never suppresses nouns, however the board is stocked" do
      [[], %w[store zoo], ["stop", "all done"]].each do |words|
        expect(described_class.incremental_word_rules(existing_words: words))
          .not_to include("Skip nouns that exist to be labelled")
      end
    end

    it "never carries the full whole-board coverage set" do
      expect(described_class.incremental_word_rules(existing_words: []))
        .not_to include(described_class::BOARD_COVERAGE_RULES)
    end
  end

  describe "SYSTEM_PROMPT" do
    it "frames the job as what a board lets someone say, not what it names" do
      expect(described_class::SYSTEM_PROMPT).to match(/request, refuse, comment, direct, repair/)
      expect(described_class::SYSTEM_PROMPT).to include("board that can only name things has failed")
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
end
