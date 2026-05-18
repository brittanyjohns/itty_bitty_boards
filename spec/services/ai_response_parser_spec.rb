require "rails_helper"

RSpec.describe AiResponseParser do
  describe ".parse" do
    it "parses a clean JSON object" do
      expect(described_class.parse('{"a":1}')).to eq({ "a" => 1 })
    end

    it "returns nil for blank input" do
      expect(described_class.parse(nil)).to be_nil
      expect(described_class.parse("")).to be_nil
      expect(described_class.parse("   ")).to be_nil
    end

    it "returns a Hash passed through unchanged" do
      h = { "a" => 1 }
      expect(described_class.parse(h)).to equal(h)
    end

    it "strips ```json fences" do
      raw = "```json\n{\"words\": [\"a\", \"b\"]}\n```"
      expect(described_class.parse(raw)).to eq({ "words" => %w[a b] })
    end

    it "strips bare ``` fences" do
      raw = "```\n{\"x\":1}\n```"
      expect(described_class.parse(raw)).to eq({ "x" => 1 })
    end

    it "tolerates trailing commas in objects and arrays" do
      raw = '{"words": ["a", "b",],}'
      expect(described_class.parse(raw)).to eq({ "words" => %w[a b] })
    end

    it "extracts the first JSON object when prose surrounds it" do
      raw = 'Here is your data: {"x": 1, "y": 2} hope this helps!'
      expect(described_class.parse(raw)).to eq({ "x" => 1, "y" => 2 })
    end

    it "returns nil for truly unparseable input" do
      expect(described_class.parse("not json at all { ] }")).to be_nil
    end
  end

  describe ".fetch_words" do
    it "returns the string array at the key" do
      raw = '{"words": ["apple", "banana", "cherry"]}'
      expect(described_class.fetch_words(raw, key: "words")).to eq(%w[apple banana cherry])
    end

    it "accepts symbol keys" do
      raw = '{"words": ["apple"]}'
      expect(described_class.fetch_words(raw, key: :words)).to eq(["apple"])
    end

    it "supports alternate keys (additional_words)" do
      raw = '{"additional_words": ["x", "y"]}'
      expect(described_class.fetch_words(raw, key: "additional_words")).to eq(%w[x y])
    end

    it "returns nil when the key is missing" do
      expect(described_class.fetch_words('{"x":1}', key: "words")).to be_nil
    end

    it "returns nil for blank or unparseable input" do
      expect(described_class.fetch_words(nil, key: "words")).to be_nil
      expect(described_class.fetch_words("garbage", key: "words")).to be_nil
    end

    it "filters non-string and blank entries" do
      raw = '{"words": ["apple", "", "  ", null, 42, "banana"]}'
      expect(described_class.fetch_words(raw, key: "words")).to eq(%w[apple banana])
    end

    it "trims whitespace from entries" do
      raw = '{"words": ["  apple ", "banana  "]}'
      expect(described_class.fetch_words(raw, key: "words")).to eq(%w[apple banana])
    end

    it "wraps a single non-array value into an array" do
      raw = '{"words": "lonely"}'
      expect(described_class.fetch_words(raw, key: "words")).to eq(["lonely"])
    end

    it "handles fenced + trailing-comma JSON" do
      raw = "```json\n{\"words\": [\"a\", \"b\",],}\n```"
      expect(described_class.fetch_words(raw, key: "words")).to eq(%w[a b])
    end
  end
end
