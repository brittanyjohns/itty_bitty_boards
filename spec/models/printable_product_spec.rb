require "rails_helper"

RSpec.describe PrintableProduct, type: :model do
  def png_io(color = ChunkyPNG::Color::WHITE) = StringIO.new(scene_png(50, 40, color))

  describe "slug" do
    it "is derived from the name when blank" do
      product = described_class.create!(name: "AAC Device Tags")

      expect(product.slug).to eq("aac-device-tags")
    end

    it "parameterizes a given slug rather than refusing it" do
      expect(described_class.create!(name: "Tags", slug: "My Tags 2").slug).to eq("my-tags-2")
    end

    it "is unique" do
      described_class.create!(name: "Tags", slug: "tags")
      duplicate = described_class.new(name: "Other", slug: "tags")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:slug]).to be_present
    end

    it "is required, so a name that parameterizes to nothing is refused" do
      product = described_class.new(name: "!!!")

      expect(product).not_to be_valid
      expect(product.errors[:slug]).to be_present
    end
  end

  it "allows only known categories and statuses" do
    expect(described_class.new(name: "x", category: "device_tag", status: "ready")).to be_valid
    expect(described_class.new(name: "x", category: "board")).not_to be_valid
    expect(described_class.new(name: "x", status: "live")).not_to be_valid
  end

  describe "canva_templates (shared CanvaTemplatesValidator)" do
    def with_templates(rows) = described_class.new(name: "Tags", canva_templates: rows)

    it "accepts a design link and a canva.link short link" do
      expect(with_templates([
        { "label" => "Voice Tag 1", "url" => "https://www.canva.com/design/DAGabc/x/view" },
        { "label" => "Name Tag", "url" => "https://canva.link/abc123" },
      ])).to be_valid
    end

    it "refuses http, a foreign host and a missing label with the kit page's messages" do
      product = with_templates([
        { "label" => "A", "url" => "http://www.canva.com/design/DAGabc/x/view" },
        { "label" => "", "url" => "https://evil.example.com/design/x" },
      ])

      expect(product).not_to be_valid
      messages = product.errors[:canva_templates].join(" | ")
      expect(messages).to include("template 1 must be an https canva.com/design/… or canva.link/… link")
      expect(messages).to include("template 2 needs a label")
      expect(messages).to include("template 2 must be an https")
    end

    it "caps the number of templates" do
      rows = Array.new(described_class::MAX_TEMPLATES + 1) { |i| { "label" => "T#{i}", "url" => "https://canva.link/t#{i}" } }

      product = with_templates(rows)

      expect(product).not_to be_valid
      expect(product.errors[:canva_templates].join).to include("at most #{described_class::MAX_TEMPLATES}")
    end
  end

  describe "artworks" do
    let(:product) { described_class.create!(name: "Tags") }

    it "stores the admin's label in blob metadata at a versioned key" do
      blob = product.attach_artwork!(io: png_io, filename: "tag.png", content_type: "image/png", label: "Voice Tag 1")

      expect(product.reload.artworks.map(&:blob_id)).to eq([blob.id])
      expect(blob.metadata["label"]).to eq("Voice Tag 1")
      expect(blob.key).to match(%r{\Aprintable_products/#{product.id}/\h{8}/tag\.png\z})
      expect(product.artwork_label(product.artworks.first)).to eq("Voice Tag 1")
    end

    it "labels an unlabelled artwork by its filename" do
      product.attach_artwork!(io: png_io, filename: "name-tag.png", content_type: "image/png")

      expect(product.artwork_label(product.reload.artworks.first)).to eq("name-tag")
    end

    it "refuses a format outside the allowlist before uploading anything" do
      expect do
        product.attach_artwork!(io: StringIO.new("<svg/>"), filename: "x.svg", content_type: "image/svg+xml")
      end.to raise_error(ArgumentError, /image\/svg\+xml/)
        .and(not_change { ActiveStorage::Blob.count })
    end

    it "refuses an oversized file before uploading anything" do
      io = png_io
      allow(io).to receive(:size).and_return(described_class::MAX_ARTWORK_BYTES + 1)

      expect { product.attach_artwork!(io: io, filename: "big.png", content_type: "image/png") }
        .to raise_error(ArgumentError, /under 25 MB/)
    end

    it "is never a download — the two are separate collections" do
      product.attach_artwork!(io: png_io, filename: "tag.png", content_type: "image/png")

      expect(product.reload.downloads).not_to be_attached
      expect(product.artwork_blob_ids.size).to eq(1)
    end

    it "is invalid when a blob outside the allowlist is attached some other way" do
      blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("GIF89a"), filename: "x.gif", content_type: "image/gif")
      product.artworks.attach(blob)

      expect(product).not_to be_valid
      expect(product.errors[:artworks].join).to include("image/gif")
    end

    it "refuses a label longer than the cap on the backstop validation" do
      blob = ActiveStorage::Blob.create_and_upload!(io: png_io, filename: "x.png", content_type: "image/png",
                                                    metadata: { "label" => "x" * 81 })
      product.artworks.attach(blob)

      expect(product).not_to be_valid
      expect(product.errors[:artworks].join).to include("label over 80")
    end

    it "truncates a long label on the attach path" do
      blob = product.attach_artwork!(io: png_io, filename: "x.png", content_type: "image/png", label: "y" * 200)

      expect(blob.metadata["label"].length).to eq(described_class::MAX_LABEL_LENGTH)
    end
  end

  describe "downloads" do
    let(:product) { described_class.create!(name: "Tags") }

    it "accepts a PDF and a PNG" do
      product.attach_download!(io: StringIO.new("%PDF-1.4"), filename: "tags.pdf", content_type: "application/pdf", label: "Instructions")
      product.attach_download!(io: png_io, filename: "tag.png", content_type: "image/png")

      expect(product.reload.ordered_downloads.map { |f| product.download_label(f) }).to eq(%w[Instructions tag])
    end

    it "refuses JPEG, which isn't a buyer file here" do
      expect { product.attach_download!(io: png_io, filename: "x.jpg", content_type: "image/jpeg") }
        .to raise_error(ArgumentError)
    end

    it "caps the number of downloads at Etsy's five" do
      described_class::MAX_DOWNLOADS.times do |i|
        product.attach_download!(io: StringIO.new("%PDF"), filename: "f#{i}.pdf", content_type: "application/pdf")
      end

      expect { product.attach_download!(io: StringIO.new("%PDF"), filename: "f.pdf", content_type: "application/pdf") }
        .to raise_error(ArgumentError, /at most 5/)
    end
  end

  describe "#compositions_using_artwork" do
    it "names the scene mockups whose slots draw an artwork" do
      product = create_printable_product(artwork_count: 2)
      first, second = product.artwork_blob_ids
      composition = SceneComposition.create!(
        owner: product, scene_template: create_device_tag_template,
        slot_art: { "tag_a" => { "source" => "product_artwork", "blob_id" => first } },
      )

      expect(product.compositions_using_artwork(first)).to eq([composition])
      expect(product.compositions_using_artwork(second)).to be_empty
    end
  end
end
