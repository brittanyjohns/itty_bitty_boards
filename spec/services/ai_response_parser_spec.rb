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
      raw = <<~JSON
        ```json
        {"words": ["a", "b"]}
        ```
      JSON
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

  describe ".fetch" do
    it "returns the value at the key" do
      expect(described_class.fetch('{"name":"Alice"}', key: "name")).to eq("Alice")
    end

    it "accepts symbol keys" do
      expect(described_class.fetch('{"name":"Alice"}', key: :name)).to eq("Alice")
    end

    it "returns nil when key is missing" do
      expect(described_class.fetch('{"x":1}', key: "y")).to be_nil
    end

    it "returns nil for unparseable input" do
      expect(described_class.fetch("garbage", key: "x")).to be_nil
    end

    it "parses a JSON-encoded string value" do
      raw = '{"payload": "{\"a\":1}"}'
      expect(described_class.fetch(raw, key: "payload")).to eq({ "a" => 1 })
    end
  end

  describe ".fetch_array" do
    it "returns the array at the key" do
      raw = '{"words": ["a", "b", "c"]}'
      expect(described_class.fetch_array(raw, key: "words")).to eq(%w[a b c])
    end

    it "returns [] when the key is missing" do
      expect(described_class.fetch_array('{"x":1}', key: "words")).to eq([])
    end

    it "returns [] for blank or unparseable input" do
      expect(described_class.fetch_array(nil, key: "words")).to eq([])
      expect(described_class.fetch_array("not json", key: "words")).to eq([])
    end

    it "wraps a single non-array value into a one-element array" do
      raw = '{"words": "lonely"}'
      expect(described_class.fetch_array(raw, key: "words")).to eq(["lonely"])
    end

    it "handles fenced + trailing-comma JSON" do
      raw = "```json\n{\"words\": [\"a\", \"b\",],}\n```"
      expect(described_class.fetch_array(raw, key: "words")).to eq(%w[a b])
    end
  end
end
