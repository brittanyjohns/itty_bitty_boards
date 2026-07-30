require "rails_helper"

RSpec.describe Images::LicenseResolution do
  describe ".normalize_type" do
    it "lowercases and collapses whitespace" do
      expect(described_class.normalize_type("CC By-SA  3.0")).to eq("cc by-sa 3.0")
    end

    it "returns an empty string for nil" do
      expect(described_class.normalize_type(nil)).to eq("")
    end
  end

  describe ".truthy?" do
    it "accepts the string and boolean forms the symbol rows use" do
      expect(described_class.truthy?("true")).to be true
      expect(described_class.truthy?("T")).to be true
      expect(described_class.truthy?("1")).to be true
      expect(described_class.truthy?(true)).to be true
    end

    it "rejects everything else" do
      expect(described_class.truthy?("false")).to be false
      expect(described_class.truthy?(nil)).to be false
    end
  end

  describe ".resolve" do
    it "returns the doc's own license when present" do
      doc = Doc.new(license: { "type" => "CC BY" })
      expect(described_class.resolve(doc)).to eq({ "type" => "CC BY" })
    end

    it "returns nil for a doc with no license and a non-OpenSymbol source" do
      doc = Doc.new(source_type: "OpenAI")
      expect(described_class.resolve(doc)).to be_nil
    end

    it "returns :protected when any matching symbol is protected" do
      OpenSymbol.create!(search_string: "cup", license: "CC BY", protected_symbol: "true")
      doc = Doc.new(source_type: "OpenSymbol", raw: "cup")
      expect(described_class.resolve(doc)).to eq(:protected)
    end

    it "returns the symbol license when every matching symbol agrees" do
      OpenSymbol.create!(search_string: "dog", license: "CC BY", protected_symbol: "false")
      OpenSymbol.create!(search_string: "dog", license: "CC By", protected_symbol: "false")
      doc = Doc.new(source_type: "OpenSymbol", raw: "dog")
      expect(described_class.resolve(doc)).to eq("CC BY")
    end

    # search_string is a label match, not provenance: two symbols can share it
    # with different licenses. We cannot know which one this doc came from.
    it "returns nil when matching symbols disagree" do
      OpenSymbol.create!(search_string: "family", license: "CC BY-SA", protected_symbol: "false")
      OpenSymbol.create!(search_string: "family", license: "public domain", protected_symbol: "false")
      doc = Doc.new(source_type: "OpenSymbol", raw: "family")
      expect(described_class.resolve(doc)).to be_nil
    end
  end
end
