require "rails_helper"

# A PrintableProduct's artwork warped into a device-tag scene.
RSpec.describe Boards::Printables::RenderSceneComposition do
  let(:product) { create_printable_product(artwork_count: 2) }
  let(:template) { create_device_tag_template(front_layer: true) }
  let(:first_artwork) { ActiveStorage::Blob.find(product.artwork_blob_ids.first) }
  let(:second_artwork) { ActiveStorage::Blob.find(product.artwork_blob_ids.last) }
  let(:composition) do
    SceneComposition.create!(owner: product, scene_template: template, slot_art: {
      "tag_a" => { "source" => "product_artwork", "blob_id" => first_artwork.id },
      "tag_b" => { "source" => "product_artwork", "blob_id" => second_artwork.id },
    })
  end

  let(:rendered_html) { [] }

  before do
    grover = instance_double(Grover, to_jpeg: "jpeg-bytes")
    allow(Grover).to receive(:new) do |html, **_opts|
      rendered_html << html
      grover
    end
  end

  def scene_body = rendered_html.last.split("<body>", 2).last

  def data_uri(blob) = "data:image/png;base64,#{Base64.strict_encode64(blob.download)}"

  it "warps each artwork's bytes into its own slot, then the front layer over them" do
    described_class.new(composition: composition).call

    body = scene_body
    expect(body.scan("matrix3d(").size).to eq(2)

    tag_a = body.index('data-slot="tag_a"')
    tag_b = body.index('data-slot="tag_b"')
    expect(body.index(data_uri(first_artwork))).to be_between(tag_a, tag_b)
    expect(body.index(data_uri(second_artwork))).to be > tag_b
    expect(body.index('class="scene-front"')).to be > body.index(data_uri(second_artwork))
  end

  it "attaches the render with a digest that includes the artwork" do
    described_class.new(composition: composition).call

    expect(composition.reload.render).to be_attached
    expect(composition).not_to be_stale

    first_artwork.update_columns(checksum: "changed")
    expect(composition.reload).to be_stale
  end

  describe "re-asserted at render time" do
    it "refuses an artwork removed from the product since the save" do
      composition
      product.artworks.find { |a| a.blob_id == second_artwork.id }.purge

      expect { described_class.new(composition: composition.reload).call }
        .to raise_error(described_class::Error, /doesn't belong to this product/)
    end

    it "refuses a board source smuggled past validation" do
      composition.update_columns(slot_art: { "tag_a" => { "source" => "page_thumbnail", "board_id" => 1, "ink" => "color", "header" => true } })

      expect { described_class.new(composition: composition.reload).call }
        .to raise_error(described_class::Error, /isn't available for this printable product/)
    end
  end
end
