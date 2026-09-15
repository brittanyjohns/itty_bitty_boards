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

  describe "text slots and overlays" do
    let(:styled_template) do
      create_scene_template(
        slots: [fridge],
        front_layer: true,
        text_slots: [scene_text_slot(key: "headline", max_chars: 80)],
        overlay_regions: [scene_overlay(key: "facts", partial: "feature_list")],
      )
    end

    # Positional, not keyword: a string-keyed hash passed to a method that takes
    # keywords is read as keywords.
    def styled_composition(text_values = {}, template = styled_template)
      SceneComposition.create!(owner: printable, scene_template: template,
                               slot_art: slot_art.slice("fridge"), text_values: text_values)
    end

    it "escapes the words, which are user input" do
      described_class.new(composition: styled_composition("headline" => "<script>alert(1)</script> & co")).call

      expect(scene_body).to include("&lt;script&gt;alert(1)&lt;/script&gt; &amp; co")
      expect(scene_body).not_to include("<script>alert(1)")
    end

    it "draws base, art, front layer, then text, then overlays" do
      described_class.new(composition: styled_composition("headline" => "Core Words")).call

      order = ['class="scene-base"', 'class="scene-art', 'class="scene-front"', 'class="scene-text', 'class="scene-overlay"']
                .map { |marker| scene_body.index(marker) }
      expect(order).to all(be_present)
      expect(order).to eq(order.sort)
    end

    it "styles the words from the template, with the font from the allowlist" do
      described_class.new(composition: styled_composition("headline" => "Core Words")).call

      expect(scene_body).to include('class="scene-text scene-font-fredoka"', 'data-max-px="48"', 'data-min-px="16"')
      expect(scene_body).to include("font-weight: 600; color: #17385c; text-align: center;")
      expect(scene_html).to include("font-family: 'Fredoka'", ".scene-font-fredoka { font-family: Fredoka")
    end

    it "falls back to the slot's default, and draws nothing for an empty default" do
      described_class.new(composition: styled_composition).call
      expect(scene_body).to include(">Printable AAC</div>")

      rendered_html.clear
      silent = create_scene_template(slots: [fridge], text_slots: [scene_text_slot(default: "")])
      described_class.new(composition: styled_composition({},silent)).call
      expect(scene_body).not_to include('class="scene-text')
    end

    it "seeds a smaller font size for longer words, before the in-page fit refines it" do
      described_class.new(composition: styled_composition("headline" => "Hi")).call
      short = scene_body[/scene-text-inner"\s+style="font-size: (\d+)px/, 1].to_i

      rendered_html.clear
      described_class.new(composition: styled_composition("headline" => "A much longer headline that needs to wrap")).call
      long = scene_body[/scene-text-inner"\s+style="font-size: (\d+)px/, 1].to_i

      expect(short).to eq(48)
      expect(long).to be < short
      expect(long).to be >= 16
    end

    it "waits for the in-page fit before the screenshot" do
      described_class.new(composition: styled_composition("headline" => "Core Words")).call

      expect(scene_opts[:wait_for_function]).to eq("window.__scene_fit === true")
      expect(scene_opts[:wait_for_function_options]).to eq(timeout: described_class::FIT_TIMEOUT_MS)
      expect(scene_body).to include("window.__scene_fit = true", "document.fonts")
    end

    it "carries no fonts, fit script or wait for a scene with no text or overlays" do
      described_class.new(composition: composition).call

      expect(scene_opts).not_to have_key(:wait_for_function)
      expect(scene_html).not_to include("@font-face")
      expect(scene_body).not_to include("__scene_fit")
    end

    it "renders every allowlisted overlay from the printable's facts" do
      overlays = SceneTemplate::OVERLAY_PARTIALS.each_with_index.map do |partial, index|
        scene_overlay(key: "o#{index}", partial: partial, box: [200, 10 + (index * 70), 180, 60])
      end
      template = create_scene_template(slots: [fridge], overlay_regions: overlays)

      described_class.new(composition: styled_composition({},template)).call

      expect(scene_body).to include('data-partial="feature_list"', 'data-partial="badges"',
                                    'data-partial="steps_row"', 'data-partial="check_pills"')
      expect(scene_body).to include("2 printable communication boards") # feature_list
      expect(scene_body).to include("2 boards, one book")                # steps_row: a set
      expect(scene_body).to include(">2 boards</span>")                  # check_pills
      expect(scene_body).to include(Printables::GalleryFacts::LETTER_SIZE_LABEL) # badges
      expect(scene_body).not_to match(/free|no sign-in/i)
    end

    describe "re-asserted at render time" do
      it "refuses an overlay partial that isn't on the allowlist" do
        composition = styled_composition
        styled_template.update_columns(overlay_regions: [scene_overlay(partial: "free_text")])

        expect { described_class.new(composition: composition.reload).call }
          .to raise_error(described_class::Error, /Unknown overlay "free_text"/)
      end

      it "refuses a font that isn't on the allowlist" do
        composition = styled_composition
        styled_template.update_columns(text_slots: [scene_text_slot(key: "headline", font: "comic-sans")])

        expect { described_class.new(composition: composition.reload).call }
          .to raise_error(described_class::Error, /font the render doesn't carry/)
      end

      it "refuses words longer than a max_chars lowered since they were saved" do
        composition = styled_composition("headline" => "Core Words")
        styled_template.update_columns(text_slots: [scene_text_slot(key: "headline", max_chars: 4)])

        expect { described_class.new(composition: composition.reload).call }
          .to raise_error(described_class::Error, /4-character limit/)
      end
    end
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
