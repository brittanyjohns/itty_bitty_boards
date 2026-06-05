require "rails_helper"

RSpec.describe Boards::InterestCategories, type: :service do
  describe ".category_for" do
    it "maps known words to their category folder label" do
      expect(described_class.category_for("apple")).to eq("Food")
      expect(described_class.category_for("scared")).to eq("Feelings")
      expect(described_class.category_for("toilet")).to eq("Bathroom")
      expect(described_class.category_for("dinosaurs")).to eq("Play")
    end

    it "is case- and whitespace-insensitive" do
      expect(described_class.category_for("  ApPlE ")).to eq("Food")
    end

    it "returns nil for a word with no category" do
      expect(described_class.category_for("grandma")).to be_nil
      expect(described_class.category_for("")).to be_nil
    end
  end

  describe "lexicon integrity" do
    it "maps every word to exactly one category (no ambiguous reverse index)" do
      all_words = described_class::KEYWORDS.values.flatten
      expect(all_words).to eq(all_words.uniq)
    end

    it "exposes the category labels" do
      expect(described_class.categories).to include("Food", "Feelings", "Bathroom", "Play")
    end
  end
end
