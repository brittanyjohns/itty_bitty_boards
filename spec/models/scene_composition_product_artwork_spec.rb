require "rails_helper"

# The product_artwork art source and a PrintableProduct as a composition owner.
RSpec.describe SceneComposition, type: :model do
  let(:product) { create_printable_product(artwork_count: 2) }
  let(:template) { create_device_tag_template }
  let(:first_artwork) { product.artwork_blob_ids.first }
  let(:second_artwork) { product.artwork_blob_ids.last }

  def artwork(blob_id) = { "source" => "product_artwork", "blob_id" => blob_id.to_s }

  # A braceless `"tag_a" => ...` argument arrives as keywords, so both are merged.
  def build_for(owner, slot_art = {}, scene_template: template, **keyword_art)
    art = slot_art.merge(keyword_art.transform_keys(&:to_s))
    described_class.new(owner: owner, scene_template: scene_template, slot_art: art)
  end

  describe "validation" do
    it "accepts the product's own artwork, normalizing the id" do
      composition = build_for(product, "tag_a" => artwork(first_artwork), "tag_b" => artwork(second_artwork))

      expect(composition).to be_valid
      expect(composition.slot_art["tag_a"]).to eq("source" => "product_artwork", "blob_id" => first_artwork)
    end

    it "refuses an artwork blob from another product" do
      stranger = create_printable_product(artwork_count: 1)
      composition = build_for(product, "tag_a" => artwork(stranger.artwork_blob_ids.first))

      expect(composition).not_to be_valid
      expect(composition.errors[:slot_art].join).to include("pick one of this product's artworks")
    end

    it "refuses a board-only source on a product" do
      open_template = create_scene_template(category: "device_tag", slots: [scene_slot(key: "tag_a", accepts: SceneTemplate.normalize_slot({})["accepts"])])
      composition = build_for(product, { "tag_a" => { "source" => "page_thumbnail", "board_id" => 1, "ink" => "color" } },
                              scene_template: open_template)

      expect(composition).not_to be_valid
      expect(composition.errors[:slot_art].join).to include("page thumbnail isn't available here")
    end

    it "refuses product artwork on a board printable" do
      owner = create(:user)
      board = create(:board, user: owner)
      printable = BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id])
      board_template = create_scene_template(slots: [scene_slot(key: "fridge", accepts: %w[product_artwork page_thumbnail])])
      composition = build_for(printable, { "fridge" => artwork(first_artwork) }, scene_template: board_template)

      expect(composition).not_to be_valid
      expect(composition.errors[:slot_art].join).to include("product artwork isn't available here")
    end

    it "only composites a device tag into a device-tag scene" do
      composition = build_for(product, {}, scene_template: create_scene_template)

      expect(composition).not_to be_valid
      expect(composition.errors[:scene_template].join).to include("is a board scene, not a device_tag scene")
    end

    it "offers a product only its own sources" do
      expect(build_for(product, {}).allowed_sources).to contain_exactly("product_artwork", "upload")
      expect(build_for(product, {}).owner_board_ids).to eq([])
    end
  end

  describe "#current_render_digest" do
    let(:composition) { described_class.create!(owner: product, scene_template: template, slot_art: { "tag_a" => artwork(first_artwork) }) }

    it "changes when a slot draws a different artwork" do
      before = composition.current_render_digest
      composition.update!(slot_art: { "tag_a" => artwork(second_artwork) })

      expect(composition.current_render_digest).not_to eq(before)
    end

    it "changes when the artwork's bytes change" do
      before = composition.current_render_digest
      ActiveStorage::Blob.find(first_artwork).update_columns(checksum: "different")

      expect(composition.current_render_digest).not_to eq(before)
    end
  end

  it "never prunes the product's artworks with its own unused uploads" do
    composition = described_class.create!(owner: product, scene_template: template, slot_art: { "tag_a" => artwork(first_artwork) })
    composition.attach_slot_upload!(io: StringIO.new(scene_png), filename: "stale.png", content_type: "image/png")

    composition.prune_unused_uploads!

    expect(composition.slot_uploads).to be_empty
    expect(product.reload.artwork_blob_ids).to include(first_artwork)
  end
end
