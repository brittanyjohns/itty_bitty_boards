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
  end

  describe "limit" do
    it "clamps the limit to MAX_LIMIT" do
      expect(described_class.new(limit: 9_999).limit).to eq(described_class::MAX_LIMIT)
    end

    it "clamps a zero or negative limit up to 1" do
      expect(described_class.new(limit: 0).limit).to eq(1)
    end
  end

  describe "result shape" do
    it "returns both the tile URL and the full-resolution original" do
      image_with_doc(label: "apple")
      result = described_class.new.call("apple").first

      expect(result[:src]).to be_present
      expect(result[:original_url]).to be_present
      expect(result).to include(:id, :label, :match, :content_type, :width, :height,
                                :source_type, :license, :commercial_safe,
                                :attribution_required, :share_alike)
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
  end
end
