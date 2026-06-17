require "rails_helper"

RSpec.describe Boards::InterestCategories, type: :service do
  describe ".category_for" do
    it "maps known words to their category folder label" do
      expect(described_class.category_for("apple")).to eq("Food")
      expect(described_class.category_for("scared")).to eq("Feelings")
      expect(described_class.category_for("toilet")).to eq("Bathroom")
      expect(described_class.category_for("dinosaurs")).to eq("Play")
    end

    it "maps words in the new expanded categories" do
      expect(described_class.category_for("dog")).to eq("Animals")
      expect(described_class.category_for("crayon")).to eq("Art & Craft")
      expect(described_class.category_for("shirt")).to eq("Clothing")
      expect(described_class.category_for("grandma")).to eq("Family & People")
      expect(described_class.category_for("medicine")).to eq("Health & Body")
      expect(described_class.category_for("couch")).to eq("Home")
      expect(described_class.category_for("guitar")).to eq("Music")
      expect(described_class.category_for("flower")).to eq("Nature & Outdoors")
      expect(described_class.category_for("library")).to eq("Places")
      expect(described_class.category_for("pencil")).to eq("School")
      expect(described_class.category_for("please")).to eq("Social")
      expect(described_class.category_for("soccer")).to eq("Sports")
      expect(described_class.category_for("tablet")).to eq("Technology")
      expect(described_class.category_for("bus")).to eq("Transportation")
    end

    it "is case- and whitespace-insensitive" do
      expect(described_class.category_for("  ApPlE ")).to eq("Food")
    end

    it "returns nil for a word with no category" do
      expect(described_class.category_for("spaceship")).to be_nil
      expect(described_class.category_for("")).to be_nil
    end
  end

  describe "lexicon integrity" do
    it "maps every word to exactly one category (no ambiguous reverse index)" do
      all_words = described_class::KEYWORDS.values.flatten
      expect(all_words).to eq(all_words.uniq)
    end

    it "has at least 15 categories" do
      expect(described_class.categories.size).to be >= 15
    end

    it "exposes the category labels" do
      expect(described_class.categories).to include(
        "Food", "Feelings", "Bathroom", "Play",
        "Animals", "Art & Craft", "Clothing", "Family & People",
        "Health & Body", "Home", "Music", "Nature & Outdoors",
        "Places", "School", "Social", "Sports", "Technology", "Transportation"
      )
    end
  end
end
