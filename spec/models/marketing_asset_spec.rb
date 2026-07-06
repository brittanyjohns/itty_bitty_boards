require "rails_helper"

RSpec.describe MarketingAsset, type: :model do
  let(:pdf_bytes) { "%PDF-1.4 fake pdf bytes" }

  describe "validations" do
    it "requires a slug" do
      expect(described_class.new(slug: nil)).not_to be_valid
    end

    it "rejects an invalid slug format" do
      expect(described_class.new(slug: "Not A Slug")).not_to be_valid
      expect(described_class.new(slug: "classroom-kit")).to be_valid
    end

    it "enforces slug uniqueness" do
      described_class.create!(slug: "classroom-kit")
      dup = described_class.new(slug: "classroom-kit")
      expect(dup).not_to be_valid
    end
  end

  describe ".upsert_pdf!" do
    it "creates the asset and attaches the PDF at the deterministic key" do
      asset = described_class.upsert_pdf!(slug: "classroom-kit", bytes: pdf_bytes, title: "Kit")

      expect(asset).to be_persisted
      expect(asset.title).to eq("Kit")
      expect(asset.file).to be_attached
      expect(asset.file.key).to eq("marketing_assets/classroom-kit.pdf")
    end

    it "is idempotent: re-running replaces bytes but keeps the slug and stable key" do
      described_class.upsert_pdf!(slug: "classroom-kit", bytes: pdf_bytes, title: "Kit")

      expect {
        described_class.upsert_pdf!(slug: "classroom-kit", bytes: "%PDF new bytes", title: "Kit v2")
      }.not_to change(described_class, :count)

      asset = described_class.find_by(slug: "classroom-kit")
      expect(asset.title).to eq("Kit v2")
      expect(asset.file.key).to eq("marketing_assets/classroom-kit.pdf")
    end
  end

  describe "#file_url" do
    it "returns nil when no file is attached" do
      expect(described_class.new(slug: "x").file_url).to be_nil
    end

    it "builds a CDN URL from the stable key when CDN_HOST is set" do
      asset = described_class.upsert_pdf!(slug: "classroom-kit", bytes: pdf_bytes)

      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("CDN_HOST").and_return("https://cdn.example.com")

      expect(asset.file_url).to eq("https://cdn.example.com/marketing_assets/classroom-kit.pdf")
    end
  end
end
