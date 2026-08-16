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
  end
end
