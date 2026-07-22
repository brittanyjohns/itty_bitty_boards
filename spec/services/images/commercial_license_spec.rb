require "rails_helper"

RSpec.describe Images::CommercialLicense do
  def result_for(license:, source_type: "ObfImport", include_share_alike: false)
    doc = Doc.new(license: license, source_type: source_type)
    described_class.for(doc, include_share_alike: include_share_alike)
  end

  describe "generated images" do
    it "treats OpenAI-generated docs as safe with no obligations" do
      r = result_for(license: nil, source_type: "OpenAI")
      expect(r.commercial_safe?).to be true
      expect(r.attribution_required?).to be false
      expect(r.share_alike?).to be false
    end
  end

  describe "commercially usable licenses" do
    it "treats public domain as safe with no attribution" do
      r = result_for(license: { "type" => "public domain" })
      expect(r.commercial_safe?).to be true
      expect(r.attribution_required?).to be false
    end

    ["CC BY", "CC By", "CC By 3.0"].each do |type|
      it "treats #{type.inspect} as safe but attribution-required" do
        r = result_for(license: { "type" => type })
        expect(r.commercial_safe?).to be true
        expect(r.attribution_required?).to be true
        expect(r.share_alike?).to be false
      end
    end
  end

  describe "share-alike" do
    ["CC BY-SA", "CC By-SA 3.0"].each do |type|
      it "excludes #{type.inspect} by default" do
        r = result_for(license: { "type" => type })
        expect(r.commercial_safe?).to be false
        expect(r.share_alike?).to be true
        expect(r.attribution_required?).to be true
      end

      it "admits #{type.inspect} when include_share_alike is set" do
        r = result_for(license: { "type" => type }, include_share_alike: true)
        expect(r.commercial_safe?).to be true
        expect(r.share_alike?).to be true
      end
    end
  end

  describe "non-commercial licenses" do
    ["CC BY-NC-SA", "CC BY-NC"].each do |type|
      it "never treats #{type.inspect} as safe, even with include_share_alike" do
        r = result_for(license: { "type" => type }, include_share_alike: true)
        expect(r.commercial_safe?).to be false
        expect(r.attribution_required?).to be true
      end
    end
  end

  describe "fail-closed cases" do
    it "rejects the 'private' license type" do
      expect(result_for(license: { "type" => "private" }).commercial_safe?).to be false
    end

    it "rejects no-derivatives" do
      expect(result_for(license: { "type" => "CC By-ND" }).commercial_safe?).to be false
    end

    it "rejects an unrecognized license type" do
      expect(result_for(license: { "type" => "GPL" }).commercial_safe?).to be false
    end

    it "rejects a nil license" do
      expect(result_for(license: nil).commercial_safe?).to be false
    end

    it "rejects an empty license hash" do
      expect(result_for(license: {}).commercial_safe?).to be false
    end

    it "rejects scraped GoogleSearch docs" do
      expect(result_for(license: nil, source_type: "GoogleSearch").commercial_safe?).to be false
    end

    it "rejects docs with an unknown source_type" do
      expect(result_for(license: nil, source_type: nil).commercial_safe?).to be false
    end
  end

  describe "OpenSymbol-sourced docs" do
    it "resolves the license from the matching OpenSymbol row" do
      OpenSymbol.create!(search_string: "apple", label: "apple",
                         image_url: "https://example.com/a.png", license: "CC BY")
      doc = Doc.new(raw: "apple", source_type: "OpenSymbol", license: nil)

      r = described_class.for(doc)
      expect(r.commercial_safe?).to be true
      expect(r.attribution_required?).to be true
    end

    it "rejects a protected symbol regardless of its license string" do
      OpenSymbol.create!(search_string: "banana", label: "banana",
                         image_url: "https://example.com/b.png",
                         license: "CC BY", protected_symbol: "true")
      doc = Doc.new(raw: "banana", source_type: "OpenSymbol", license: nil)

      expect(described_class.for(doc).commercial_safe?).to be false
    end

    it "rejects a doc when ANY matching OpenSymbol is protected, regardless of row order" do
      unprotected = OpenSymbol.create!(search_string: "cherry", label: "cherry unprotected",
                                        image_url: "https://example.com/c1.png",
                                        license: "CC BY", protected_symbol: "false")
      OpenSymbol.create!(search_string: "cherry", label: "cherry protected",
                         image_url: "https://example.com/c2.png",
                         license: "CC BY", protected_symbol: "true")
      # Sanity: the unprotected row sorts first by id, so a naive `.first`
      # (no ordering guarantee aside) would miss the protected duplicate.
      expect(OpenSymbol.where(search_string: "cherry").order(:id).first).to eq(unprotected)

      doc = Doc.new(raw: "cherry", source_type: "OpenSymbol", license: nil)

      expect(described_class.for(doc).commercial_safe?).to be false
    end

    it "deterministically resolves the license when duplicates share a search_string but differ in license and none are protected" do
      lower = OpenSymbol.create!(search_string: "date", label: "date first",
                                  image_url: "https://example.com/d1.png",
                                  license: "CC BY", protected_symbol: "false")
      higher = OpenSymbol.create!(search_string: "date", label: "date second",
                                   image_url: "https://example.com/d2.png",
                                   license: "public domain", protected_symbol: "false")

      # A freshly inserted table scans in insertion order, which happens to
      # match id order — so without this UPDATE the test would pass even if
      # `.order(:id)` were deleted from resolve_license. Force the point: an
      # UPDATE on the lower-id row makes Postgres MVCC write the new tuple
      # version to the end of the heap, so an unordered sequential scan
      # would return the higher-id row first. Only an explicit `.order(:id)`
      # still returns the lower-id row here.
      lower.update!(label: "date first (updated)")

      doc = Doc.new(raw: "date", source_type: "OpenSymbol", license: nil)

      result = described_class.for(doc)
      # Both licenses are commercial-safe, so this isolates *which row won*
      # rather than accidentally testing safety: only the lower-id row (CC BY)
      # requires attribution, so a false pass here would mean the higher-id
      # row (public domain, no attribution) was picked instead.
      expect(result.type).to eq(lower.license.downcase)
      expect(result.attribution_required?).to be true
      expect(result.commercial_safe?).to be true
      expect(higher.license).to eq("public domain")
    end
  end

  describe "the returned license payload" do
    it "exposes the raw license hash for attribution rendering" do
      license = { "type" => "CC BY", "author_name" => "Sergio Palao",
                  "author_url" => "https://example.com/author" }
      expect(result_for(license: license).license).to eq(license)
    end
  end
end
