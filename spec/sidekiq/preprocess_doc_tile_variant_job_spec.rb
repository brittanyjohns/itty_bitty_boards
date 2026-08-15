require "rails_helper"

RSpec.describe PreprocessDocTileVariantJob, type: :sidekiq do
  describe "#perform" do
    it "is a no-op in staging so missing-blob errors don't pile up" do
      allow(AppEnv).to receive(:staging?).and_return(true)
      expect(Doc).not_to receive(:includes)

      described_class.new.perform(123)
    end

    it "no-ops when the doc is missing" do
      allow(AppEnv).to receive(:staging?).and_return(false)

      expect { described_class.new.perform(-1) }.not_to raise_error
    end

    # The job is the fallback every in-transaction caller defers to, so it has
    # to be the place the render actually happens — it runs with no
    # transaction of its own.
    it "renders the tile variant" do
      allow(AppEnv).to receive(:staging?).and_return(false)
      doc = FactoryBot.create(:doc)
      doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                       filename: "tile.png", content_type: "image/png")

      expect { described_class.new.perform(doc.id) }
        .to change { doc.tile_variant_processed? }.from(false).to(true)
    end

    context "when a deferred render left the original url behind" do
      let(:user) { FactoryBot.create(:user) }
      let(:image) { FactoryBot.create(:image, label: "apple", user: user) }
      let(:doc) do
        FactoryBot.create(:doc, documentable: image, user: user, current: true).tap do |d|
          d.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                         filename: "tile.png", content_type: "image/png")
        end
      end

      before { allow(AppEnv).to receive(:staging?).and_return(false) }

      it "moves the image and its tiles onto the rendition" do
        original = doc.display_url
        image.update_column(:src_url, original)
        tile = FactoryBot.create(:board_image, image: image, skip_create_voice_audio: true)
        tile.update_column(:display_image_url, original)

        described_class.new.perform(doc.id)

        expect(image.reload.src_url).to eq(doc.tile_url)
        expect(tile.reload.display_image_url).to eq(doc.tile_url)
      end

      it "leaves a tile pointing somewhere else alone" do
        image.update_column(:src_url, "https://example.com/other.png")
        tile = FactoryBot.create(:board_image, image: image, skip_create_voice_audio: true)
        tile.update_column(:display_image_url, "")

        described_class.new.perform(doc.id)

        expect(image.reload.src_url).to eq("https://example.com/other.png")
        expect(tile.reload.display_image_url).to eq("")
      end
    end
  end
end
