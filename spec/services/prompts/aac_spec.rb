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
