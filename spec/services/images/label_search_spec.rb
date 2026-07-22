require "rails_helper"

RSpec.describe Images::LabelSearch do
  let(:admin) do
    User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
  end

  # Attaches a real (tiny) blob so display_doc / display_url resolve.
  def image_with_doc(label:, user: admin, private_flag: false, license: nil, source_type: "OpenAI")
    image = Image.create!(label: label, user_id: user&.id, is_private: private_flag)
    doc = image.docs.create!(user_id: user&.id, license: license, source_type: source_type, raw: label)
    doc.image.attach(
      io: StringIO.new(file_fixture("sample.png").read),
      filename: "#{label}.png",
      content_type: "image/png",
    )
    image
  end

  before { admin }

  describe "matching" do
    it "returns an exact label match" do
      image_with_doc(label: "apple")
      results = described_class.new.call("apple")
      expect(results.map { |r| r[:label] }).to eq(["apple"])
      expect(results.first[:match]).to eq("exact")
    end

    it "falls back to prefix matching when no exact match exists" do
      image_with_doc(label: "applesauce")
      results = described_class.new.call("apple")
      expect(results.map { |r| r[:label] }).to eq(["applesauce"])
      expect(results.first[:match]).to eq("prefix")
    end

    it "skips the exact attempt when match: prefix" do
      image_with_doc(label: "applesauce")
      results = described_class.new(match: "prefix").call("apple")
      expect(results.first[:match]).to eq("prefix")
    end

    it "returns an empty array when nothing matches" do
      expect(described_class.new.call("nonexistentword")).to eq([])
    end
  end

  describe "scope" do
    it "excludes private images" do
      image_with_doc(label: "secret", private_flag: true)
      expect(described_class.new.call("secret")).to eq([])
    end

    it "excludes images owned by a non-admin user" do
      other = create(:user)
      image_with_doc(label: "theirs", user: other)
      expect(described_class.new.call("theirs")).to eq([])
    end

    it "excludes images with no attached doc" do
      Image.create!(label: "docless", user_id: admin.id)
      expect(described_class.new.call("docless")).to eq([])
    end

    it "never serves a non-admin user's Doc attached to a shared public Image" do
      # Real-world path: a non-admin user attaches their own Doc to a public,
      # admin-owned Image via API::ImagesController#crop / attach_doc_to_image
      # (which permits any image where is_private IS NOT TRUE). Image#display_doc(nil)
      # would resolve to docs.last with no user_id filter, so it can surface
      # that user's private photo here. Verified against production: 2,313
      # such Docs exist across 69 non-admin users.
      image = Image.create!(label: "shared", user_id: admin.id, is_private: false)

      admin_doc = image.docs.create!(user_id: admin.id, source_type: "OpenAI", raw: "shared")
      admin_doc.image.attach(
        io: StringIO.new(file_fixture("sample.png").read),
        filename: "admin.png",
        content_type: "image/png",
      )

      other = create(:user)
      other_doc = image.docs.create!(user_id: other.id, source_type: "OpenAI", raw: "shared")
      other_doc.image.attach(
        io: StringIO.new(file_fixture("sample.png").read),
        filename: "other.png",
        content_type: "image/png",
      )

      result = described_class.new.call("shared").first

      expect(result[:original_url]).to eq(admin_doc.display_url)
      expect(result[:original_url]).not_to eq(other_doc.display_url)
    end
  end

  describe "limit" do
    it "clamps the limit to MAX_LIMIT" do
      expect(described_class.new(limit: 9_999).limit).to eq(described_class::MAX_LIMIT)
    end

    it "clamps a zero or negative limit up to 1" do
      expect(described_class.new(limit: 0).limit).to eq(1)
    end

    it "treats a blank limit as absent and falls back to the default" do
      expect(described_class.new(limit: "").limit).to eq(described_class::DEFAULT_LIMIT)
      expect(described_class.new(limit: nil).limit).to eq(described_class::DEFAULT_LIMIT)
    end
  end

  describe "result shape" do
    it "returns a nil src (but a usable original_url) when the tile variant has not been processed yet" do
      image_with_doc(label: "apple")
      result = described_class.new.call("apple").first

      expect(result[:src]).to be_nil
      expect(result[:original_url]).to be_present
      expect(result).to include(:id, :label, :match, :content_type, :width, :height,
                                :source_type, :license, :commercial_safe,
                                :attribution_required, :share_alike)
    end

    it "returns a tile URL once the variant has already been processed" do
      image = image_with_doc(label: "apple")
      image.docs.last.tile_variant.processed

      result = described_class.new.call("apple").first

      expect(result[:src]).to be_present
      expect(result[:original_url]).to be_present
    end

    it "reports licensing flags from CommercialLicense" do
      image_with_doc(label: "arasaac", source_type: "ObfImport",
                     license: { "type" => "CC BY-NC-SA", "author_name" => "Sergio Palao" })
      result = described_class.new.call("arasaac").first

      expect(result[:commercial_safe]).to be false
      expect(result[:attribution_required]).to be true
      expect(result[:license]["author_name"]).to eq("Sergio Palao")
    end
  end

  describe "commercial_safe filtering" do
    it "omits unsafe images when commercial_safe is requested" do
      image_with_doc(label: "nc", source_type: "ObfImport", license: { "type" => "CC BY-NC" })
      expect(described_class.new(commercial_safe: true).call("nc")).to eq([])
    end

    it "keeps safe images when commercial_safe is requested" do
      image_with_doc(label: "mine", source_type: "OpenAI")
      expect(described_class.new(commercial_safe: true).call("mine").size).to eq(1)
    end

    it "returns unsafe images when commercial_safe is not requested" do
      image_with_doc(label: "nc2", source_type: "ObfImport", license: { "type" => "CC BY-NC" })
      expect(described_class.new.call("nc2").size).to eq(1)
    end

    it "admits share-alike images only with include_share_alike" do
      image_with_doc(label: "sa", source_type: "ObfImport", license: { "type" => "CC BY-SA" })

      expect(described_class.new(commercial_safe: true).call("sa")).to eq([])
      expect(described_class.new(commercial_safe: true, include_share_alike: true).call("sa").size).to eq(1)
    end

    it "does not under-report when safe results exist beyond the SQL LIMIT before filtering" do
      # Three non-safe images ordered ahead of one safe image. With limit: 1,
      # a naive `.limit(1)` in SQL followed by Ruby-side filtering would only
      # ever see the first (unsafe) row and return [] — even though a safe
      # image exists for this label.
      3.times { |i| image_with_doc(label: "ranked", source_type: "ObfImport", license: { "type" => "CC BY-NC" }) }
      safe_image = image_with_doc(label: "ranked", source_type: "OpenAI")

      results = described_class.new(limit: 1, commercial_safe: true).call("ranked")

      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq(safe_image.id)
    end
  end
end
