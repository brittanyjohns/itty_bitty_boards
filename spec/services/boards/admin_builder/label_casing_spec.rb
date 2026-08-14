require "rails_helper"

RSpec.describe Boards::AdminBuilder::LabelCasing do
  describe ".sanitize" do
    it "folds an identifier-style label back into display text" do
      expect(described_class.sanitize("snack_time")).to eq("snack time")
      expect(described_class.sanitize("  all   done  ")).to eq("all done")
    end

    it "survives a nil" do
      expect(described_class.sanitize(nil)).to eq("")
    end
  end

  describe ".apply" do
    it "folds the model's Title Case down to the AAC lowercase default" do
      expect(described_class.apply("Food")).to eq("food")
      expect(described_class.apply("All Done")).to eq("all done")
    end

    # Delegated to Labels::CaseNormalizer, which judges per word. Asserted here
    # because these are the cases a future "simplification" would break.
    it "leaves a capital that is past the first letter alone" do
      expect(described_class.apply("iPad")).to eq("iPad")
      expect(described_class.apply("TV")).to eq("TV")
      expect(described_class.apply("McDonald's")).to eq("McDonald's")
      expect(described_class.apply("HELP")).to eq("HELP")
    end

    it "keeps the standalone pronoun capitalized" do
      expect(described_class.apply("i")).to eq("I")
      expect(described_class.apply("I")).to eq("I")
    end

    # A category tile's label is authored: an AAC board leans on the capital to
    # separate a page you open from a word you speak.
    it "never touches a door tile" do
      expect(described_class.apply("Food", door: true)).to eq("Food")
      expect(described_class.apply("Snack Time", door: true)).to eq("Snack Time")
    end

    # CaseNormalizer has no proper-noun detection and would fold "Sarah" — the
    # model's own flag is the only signal there is.
    it "keeps a label the model flagged as a proper noun" do
      expect(described_class.apply("Sarah", proper_noun: true)).to eq("Sarah")
      expect(described_class.apply("Sarah")).to eq("sarah")
    end

    # An over-eager flag on a word with no capital would otherwise be a silent
    # no-op dressed up as a rule.
    it "ignores the flag when the label carries no capital" do
      expect(described_class.apply("apple", proper_noun: true)).to eq("apple")
    end

    it "sentence-cases a phrase rather than lowercasing it" do
      expect(described_class.apply("i want more", part_of_speech: "phrase")).to eq("I want more")
    end
  end

  describe ".proper_noun?" do
    it "accepts the boolean and the string the model actually returns" do
      expect(described_class.proper_noun?({ "proper_noun" => true })).to be(true)
      expect(described_class.proper_noun?({ "proper_noun" => "true" })).to be(true)
    end

    it "is false for anything else" do
      expect(described_class.proper_noun?({})).to be(false)
      expect(described_class.proper_noun?({ "proper_noun" => false })).to be(false)
      expect(described_class.proper_noun?({ "proper_noun" => "no" })).to be(false)
    end
  end
end
