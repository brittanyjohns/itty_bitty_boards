require "rails_helper"

RSpec.describe Images::RedistributionLicense do
  let(:user)  { create(:user) }
  let(:other) { create(:user) }

  def result_for(doc, exporting_user: user)
    described_class.for(doc, exporting_user: exporting_user)
  end

  # THE case this service exists for. User uploads were historically created
  # with no source_type; a "nil is untrusted" rule would drop a user's own
  # photos from their own export.
  describe "a user's own uploads" do
    it "bundles a legacy upload with a nil source_type" do
      doc = Doc.new(user_id: user.id, source_type: nil)
      r = result_for(doc)
      expect(r.bundlable?).to be true
      expect(r.owned_by_user?).to be true
    end

    it "bundles an upload stamped with the User source type" do
      doc = Doc.new(user_id: user.id, source_type: Doc::SOURCE_TYPE_USER)
      expect(result_for(doc).bundlable?).to be true
    end

    it "bundles when the parent Image is the user's even if the doc has no user_id" do
      image = create(:image, user: user)
      doc = Doc.new(documentable: image, source_type: nil)
      expect(result_for(doc).bundlable?).to be true
    end

    it "does not bundle another user's upload" do
      doc = Doc.new(user_id: other.id, source_type: Doc::SOURCE_TYPE_USER)
      r = result_for(doc)
      expect(r.bundlable?).to be false
      expect(r.owned_by_user?).to be false
    end
  end

  # Board.from_obf stamps ObfImport docs with the importing user's id. A
  # user_id match must NOT be read as authorship, or imported proprietary
  # symbols would be re-exported as the user's own work.
  describe "imported content stamped with the importing user's id" do
    it "does not treat an ObfImport doc as user-authored" do
      doc = Doc.new(user_id: user.id, source_type: "ObfImport", license: nil)
      r = result_for(doc)
      expect(r.bundlable?).to be false
      expect(r.owned_by_user?).to be false
    end

    it "still bundles an ObfImport doc that declares a redistributable license" do
      doc = Doc.new(user_id: user.id, source_type: "ObfImport", license: { "type" => "CC BY" })
      expect(result_for(doc).bundlable?).to be true
    end
  end

  describe "generated and library content" do
    it "bundles AI-generated docs" do
      expect(result_for(Doc.new(source_type: "OpenAI")).bundlable?).to be true
    end

    it "bundles SpeakAnyWay-owned uploads" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      image = create(:image, user: admin)
      doc = Doc.new(documentable: image, source_type: nil)
      r = result_for(doc)
      expect(r.bundlable?).to be true
      expect(r.owned_by_user?).to be false
    end

    it "never bundles a protected symbol, even on the user's own image" do
      OpenSymbol.create!(search_string: "cup", license: "CC BY", protected_symbol: "true")
      image = create(:image, user: user)
      doc = Doc.new(documentable: image, user_id: user.id, source_type: "OpenSymbol", raw: "cup")
      r = result_for(doc)
      expect(r.bundlable?).to be false
      expect(r.reason).to match(/proprietary/i)
    end

    it "never bundles scraped web images" do
      doc = Doc.new(source_type: "GoogleSearch")
      expect(result_for(doc).bundlable?).to be false
    end
  end

  # The other reason this is not CommercialLicense: NC forbids commercial use
  # and ND forbids derivatives; neither forbids redistribution.
  describe "license families" do
    {
      "public domain"    => false,
      "CC0"              => false,
      "CC0 1.0"          => false,
      "CC BY"            => true,
      "CC BY 4.0"        => true,
      "CC BY-SA 3.0"     => true,
      "CC BY-NC"         => true,
      "CC BY-ND"         => true,
      "CC BY-NC-SA 4.0"  => true,
    }.each do |type, attribution|
      it "bundles #{type.inspect}" do
        doc = Doc.new(source_type: "ObfImport", license: { "type" => type })
        r = result_for(doc)
        expect(r.bundlable?).to be true
        expect(r.attribution_required?).to be attribution
      end
    end

    it "does not bundle an unrecognized license" do
      doc = Doc.new(source_type: "ObfImport", license: { "type" => "All Rights Reserved" })
      r = result_for(doc)
      expect(r.bundlable?).to be false
      expect(r.reason).to be_present
    end

    it "does not bundle when there is no license at all" do
      expect(result_for(Doc.new(source_type: "ObfImport")).bundlable?).to be false
    end
  end

  describe "no exporting user" do
    it "fails closed rather than raising" do
      doc = Doc.new(user_id: user.id, source_type: nil)
      expect(result_for(doc, exporting_user: nil).bundlable?).to be false
    end
  end
end

RSpec.describe Images::RedistributionLicense, "text tiles" do
  let(:owner) { create(:user) }
  let(:stranger) { create(:user) }
  let(:doc) do
    create(:image, user: owner).docs.create!(
      source_type: Doc::SOURCE_TYPE_TEXT_TILE, user_id: owner.id,
    )
  end

  # Rendered in-house from the user's own words in an OFL font. Without this
  # the predicate falls through to "no redistributable license on record" and
  # text tiles vanish from OBF/OBZ exports with no error.
  it "is bundlable for the owner" do
    expect(described_class.for(doc, exporting_user: owner)).to be_bundlable
  end

  it "is bundlable for a teammate exporting a shared board" do
    result = described_class.for(doc, exporting_user: stranger)

    expect(result).to be_bundlable
    expect(result).not_to be_attribution_required
  end
end
