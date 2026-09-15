require "rails_helper"

RSpec.describe Boards::Printables::RenderSceneComposition do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:other) { create(:board, user: owner, name: "Feelings") }
  let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id, other.id]) }

  let(:fridge) { scene_slot(key: "fridge") }
  let(:tablet) do
    scene_slot(key: "tablet", kind: "tablet", finish: "glare", accepts: %w[device_screen upload],
               quad: [[200, 40], [380, 40], [380, 160], [200, 160]])
  end
  let(:template) { create_scene_template(slots: [fridge, tablet], front_layer: true) }

  let(:slot_art) do
    {
      "fridge" => { "source" => "page_thumbnail", "board_id" => board.id, "ink" => "color", "header" => true },
      "tablet" => { "source" => "device_screen", "board_id" => other.id },
    }
  end
  let(:composition) { SceneComposition.create!(owner: printable, scene_template: template, slot_art: slot_art) }

  # Grover shells out to headless Chrome; these specs care about what gets
  # rendered and attached, not about the pixels.
  let(:rendered_html) { [] }
  let(:rendered_opts) { [] }

  before do
    grover = instance_double(Grover, to_png: "png-bytes", to_jpeg: "jpeg-bytes")
    allow(Grover).to receive(:new) do |html, **opts|
      rendered_html << html
      rendered_opts << opts
      grover
    end
    allow_any_instance_of(Boards::Printables::RenderPageThumbnails)
      .to receive(:trim_trailing_blank) { |_, png| [png, 600, 700] }
  end

  def scene_index = rendered_html.index { |html| html.include?('class="scene-stage"') }
  def scene_html = rendered_html[scene_index]
  def scene_opts = rendered_opts[scene_index]

  # The body only — the layout's <style> names every class too.
  def scene_body = scene_html.split("<body>", 2).last

  it "warps one matrix3d per filled slot" do
    described_class.new(composition: composition).call

    expect(scene_body.scan("matrix3d(").size).to eq(2)
    expect(scene_body).to include('data-slot="fridge"', 'data-slot="tablet"')
    expect(scene_body).to include("finish-shadow", "finish-glare")
  end

  it "leaves an unfilled slot as the bare base image" do
    composition.update!(slot_art: slot_art.slice("fridge"))

    described_class.new(composition: composition).call

    expect(scene_body.scan("matrix3d(").size).to eq(1)
    expect(scene_body).not_to include('data-slot="tablet"')
  end

  it "draws the base first, then the art, then the front layer over it" do
    described_class.new(composition: composition).call

    base = scene_body.index('class="scene-base"')
    last_art = scene_body.rindex('class="scene-art')
    front = scene_body.index('class="scene-front"')

    expect(base).to be < scene_body.index('class="scene-art')
    expect(front).to be > last_art
  end

  it "skips the front layer when the template has none" do
    plain = create_scene_template(slots: [fridge])
    composition = SceneComposition.create!(owner: printable, scene_template: plain, slot_art: slot_art.slice("fridge"))

    described_class.new(composition: composition).call

    expect(scene_body).not_to include('class="scene-front"')
  end

  # device_scale_factor MUST be nested in viewport — Grover silently drops a
  # top-level one, which is how the listing gallery shipped 1x images.
  it "renders at the template's aspect with the scale nested inside viewport" do
    described_class.new(composition: composition).call

    expect(scene_opts[:viewport]).to eq(width: 1200, height: 900, device_scale_factor: 2)
    expect(scene_opts).not_to have_key(:device_scale_factor)
  end

  it "keeps a wide template wide rather than cropping to a square" do
    wide = create_scene_template(width: 800, height: 300, slots: [fridge])
    composition = SceneComposition.create!(owner: printable, scene_template: wide, slot_art: slot_art.slice("fridge"))

    described_class.new(composition: composition).call

    expect(scene_opts[:viewport]).to include(width: 1200, height: 450)
    expect(scene_body).to include("scale(1.5)")
  end

  it "renders only the thumbnail passes a slot asks for" do
    composition.update!(slot_art: {
      "fridge" => { "source" => "page_thumbnail", "board_id" => board.id, "ink" => "low_ink", "header" => false },
    })
    allow(Boards::Printables::RenderPageThumbnails).to receive(:new).and_call_original

    described_class.new(composition: composition).call

    expect(Boards::Printables::RenderPageThumbnails).to have_received(:new).once
    expect(Boards::Printables::RenderPageThumbnails)
      .to have_received(:new).with(boards: [board], hide_colors: true, hide_header: true)
  end

  it "puts the board inside the app chrome for a device screen, sized to the slot" do
    allow(Boards::Printables::RenderDeviceScreen).to receive(:new).and_call_original

    described_class.new(composition: composition).call

    expect(Boards::Printables::RenderDeviceScreen).to have_received(:new)
      .with(hash_including(title: anything, scene: an_object_having_attributes(key: "tablet")))
  end

  it "inlines an uploaded picture" do
    blob = composition.attach_slot_upload!(io: StringIO.new(scene_png(40, 30)), filename: "hand.png", content_type: "image/png")
    composition.update!(slot_art: { "tablet" => { "source" => "upload", "blob_id" => blob.id } })

    described_class.new(composition: composition).call

    expect(scene_body).to include("data:image/png;base64,#{Base64.strict_encode64(scene_png(40, 30))}")
  end

  it "attaches the JPEG and stamps the digest, so the render reads current" do
    described_class.new(composition: composition).call
    composition.reload

    expect(composition.render).to be_attached
    expect(composition.render.blob.content_type).to eq("image/jpeg")
    expect(composition.render.download).to eq("jpeg-bytes")
    expect(composition.render_digest).to eq(composition.current_render_digest)
    expect(composition).not_to be_stale
  end

  describe "re-asserted at render time" do
    it "refuses an upload blob that belongs to another composition" do
      elsewhere = SceneComposition.create!(owner: printable, scene_template: template)
      blob = elsewhere.attach_slot_upload!(io: StringIO.new(scene_png), filename: "x.png", content_type: "image/png")
      composition.update_columns(slot_art: { "tablet" => { "source" => "upload", "blob_id" => blob.id } })

      expect { described_class.new(composition: composition.reload).call }
        .to raise_error(described_class::Error, /doesn't belong/)
      expect(composition.reload.render).not_to be_attached
    end

    it "refuses a board that isn't part of the printable" do
      stranger = create(:board, user: owner)
      composition.update_columns(slot_art: {
        "fridge" => { "source" => "page_thumbnail", "board_id" => stranger.id, "ink" => "color", "header" => true },
      })

      expect { described_class.new(composition: composition.reload).call }
        .to raise_error(described_class::Error, /isn't part of this printable/)
    end
  end

  it "refuses to ship a blank placeholder when a filled slot's art won't render" do
    allow_any_instance_of(Boards::Printables::RenderPageThumbnails).to receive(:call).and_return({})

    expect { described_class.new(composition: composition).call }
      .to raise_error(described_class::Error, /Fridge/)
    expect(composition.reload.render).not_to be_attached
  end
end
