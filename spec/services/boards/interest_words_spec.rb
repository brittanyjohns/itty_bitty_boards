require "rails_helper"

RSpec.describe Boards::InterestWords, type: :service do
  describe "MAX_INTERESTS" do
    it "is 20" do
      expect(described_class::MAX_INTERESTS).to eq(20)
    end
  end

  describe ".normalize_list" do
    it "normalizes plain string interests" do
      result = described_class.normalize_list(["pizza", " Trains ", ""])
      expect(result).to eq(["pizza", "Trains"])
    end

    it "deduplicates after normalization" do
      result = described_class.normalize_list(["pizza", "pizza", " pizza "])
      expect(result).to eq(["pizza"])
    end

    it "caps at MAX_INTERESTS" do
      words = (1..25).map { |n| "word#{n}" }
      result = described_class.normalize_list(words)
      expect(result.size).to eq(20)
    end

    it "handles { word, category } hash entries" do
      result = described_class.normalize_list([
        { "word" => "pizza", "category" => "Food" },
        { "word" => "dog", "category" => "Animals" },
      ])
      expect(result).to eq(["pizza", "dog"])
    end

    it "handles a mix of strings and hashes" do
      result = described_class.normalize_list([
        "trains",
        { "word" => "pizza", "category" => "Food" },
        "grandma",
      ])
      expect(result).to eq(["trains", "pizza", "grandma"])
    end

    it "handles ActionController::Parameters like hashes" do
      entry = ActionController::Parameters.new("word" => "pizza", "category" => "Food")
      result = described_class.normalize_list([entry])
      expect(result).to eq(["pizza"])
    end
  end

  describe ".extract_categories" do
    it "returns an empty hash for plain strings" do
      result = described_class.extract_categories(["pizza", "trains"])
      expect(result).to eq({})
    end

    it "extracts category from hash entries" do
      result = described_class.extract_categories([
        { "word" => "pizza", "category" => "Food" },
        { "word" => "dog", "category" => "Animals" },
      ])
      expect(result).to eq({ "pizza" => "Food", "dog" => "Animals" })
    end

    it "ignores entries without a category" do
      result = described_class.extract_categories([
        { "word" => "pizza", "category" => "Food" },
        { "word" => "grandma" },
      ])
      expect(result).to eq({ "pizza" => "Food" })
    end

    it "handles a mix of strings and hashes" do
      result = described_class.extract_categories([
        "trains",
        { "word" => "pizza", "category" => "Food" },
      ])
      expect(result).to eq({ "pizza" => "Food" })
    end

    it "handles ActionController::Parameters" do
      entry = ActionController::Parameters.new("word" => "pizza", "category" => "Food")
      result = described_class.extract_categories([entry])
      expect(result).to eq({ "pizza" => "Food" })
    end
  end
end
