require "rails_helper"

RSpec.describe SceneComposition, type: :model do
  let(:owner) { create(:user) }
  let(:board) { create(:board, user: owner, name: "Core Words") }
  let(:other) { create(:board, user: owner, name: "Feelings") }
  let(:stranger_board) { create(:board, user: owner, name: "Not in the printable") }
  let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id, other.id]) }
  let(:template) do
    create_scene_template(slots: [
      scene_slot(key: "fridge"),
      scene_slot(key: "tablet", kind: "tablet", accepts: %w[device_screen], quad: [[200, 40], [380, 40], [380, 160], [200, 160]]),
    ])
  end

  def page(board_id, ink: "color", header: true)
    { "source" => "page_thumbnail", "board_id" => board_id, "ink" => ink, "header" => header }
  end

  def build_composition(slot_art = {})
    described_class.new(owner: printable, scene_template: template, slot_art: slot_art)
  end

  describe "slot_art validation" do
    it "accepts a page render of a board in the printable" do
      expect(build_composition("fridge" => page(board.id))).to be_valid
    end

    it "refuses a board that isn't part of the printable" do
      composition = build_composition("fridge" => page(stranger_board.id))

      expect(composition).not_to be_valid
      expect(composition.errors[:slot_art].join).to include("pick a board from this printable")
    end

    it "refuses an art source the slot doesn't accept" do
      composition = build_composition("tablet" => page(board.id))

      expect(composition).not_to be_valid
      expect(composition.errors[:slot_art].join).to include("doesn't take page thumbnail")
    end

    it "refuses a slot key the template doesn't have" do
      composition = build_composition("window" => page(board.id))

      expect(composition).not_to be_valid
      expect(composition.errors[:slot_art].join).to include("(window)")
    end

    it "refuses an unknown ink" do
      composition = build_composition("fridge" => page(board.id, ink: "sepia"))

      expect(composition).not_to be_valid
    end

    it "drops a slot left blank, so it renders the base image" do
      composition = build_composition("fridge" => { "source" => "" }, "tablet" => { "source" => "device_screen", "board_id" => other.id.to_s })
      composition.valid?

      expect(composition.slot_art).to eq("tablet" => { "source" => "device_screen", "board_id" => other.id })
    end

    it "casts the header checkbox's form values" do
      composition = build_composition("fridge" => { "source" => "page_thumbnail", "board_id" => board.id.to_s, "header" => "0" })
      composition.valid?

      expect(composition.slot_art["fridge"]).to include("header" => false, "ink" => "color", "board_id" => board.id)
    end

    it "only accepts an upload blob attached to THIS composition" do
      mine = described_class.create!(owner: printable, scene_template: template)
      theirs = described_class.create!(owner: printable, scene_template: template)
      own_blob = mine.attach_slot_upload!(io: StringIO.new(scene_png), filename: "a.png", content_type: "image/png")
      their_blob = theirs.attach_slot_upload!(io: StringIO.new(scene_png), filename: "b.png", content_type: "image/png")

      mine.slot_art = { "fridge" => { "source" => "upload", "blob_id" => their_blob.id } }
      expect(mine).not_to be_valid
      expect(mine.errors[:slot_art].join).to include("upload a picture")

      mine.slot_art = { "fridge" => { "source" => "upload", "blob_id" => own_blob.id } }
      expect(mine).to be_valid
    end
  end

  describe "template" do
    it "must be calibrated to start a composition" do
      draft = create_scene_template(status: "draft")

      composition = described_class.new(owner: printable, scene_template: draft)
      expect(composition).not_to be_valid
      expect(composition.errors[:scene_template].join).to include("calibrated")
    end

    it "must be a board scene for a board printable" do
      tag_scene = create_scene_template(category: "device_tag")

      composition = described_class.new(owner: printable, scene_template: tag_scene)
      expect(composition).not_to be_valid
      expect(composition.errors[:scene_template].join).to include("device_tag")
    end

    it "keeps rendering once its template is archived" do
      composition = described_class.create!(owner: printable, scene_template: template, slot_art: { "fridge" => page(board.id) })
      template.archive!

      expect(composition.reload).to be_valid
    end
  end

  it "refuses a listing from a different printable" do
    elsewhere = BoardPrintable.create!(board: other, status: "complete", board_ids: [other.id])
    listing = elsewhere.etsy_listings.create!

    composition = build_composition.tap { |c| c.board_printable_listing = listing }
    expect(composition).not_to be_valid
    expect(composition.errors[:board_printable_listing]).to be_present
  end

  describe "render digest" do
    let(:composition) { described_class.create!(owner: printable, scene_template: template, slot_art: { "fridge" => page(board.id) }) }

    it "is stable for the same inputs" do
      expect(composition.current_render_digest).to eq(composition.reload.current_render_digest)
    end

    it "changes with the art choice" do
      before = composition.current_render_digest
      composition.update!(slot_art: { "fridge" => page(board.id, ink: "low_ink") })

      expect(composition.current_render_digest).not_to eq(before)
    end

    it "changes when the template is recalibrated" do
      before = composition.current_render_digest
      template.update!(slots: template.slots.map { |s| s.merge("bleed_px" => 3) })

      expect(composition.reload.current_render_digest).not_to eq(before)
    end

    it "changes when a board it draws is edited" do
      before = composition.current_render_digest
      board.update_columns(updated_at: 1.hour.from_now)

      expect(composition.current_render_digest).not_to eq(before)
    end

    it "is stale until rendered, current after, and stale again when a board changes" do
      expect(composition).to be_stale

      composition.attach_render!(bytes: "jpeg-bytes", digest: composition.current_render_digest)
      expect(composition.reload).not_to be_stale

      board.update_columns(updated_at: 1.hour.from_now)
      expect(composition.reload).to be_stale
    end
  end

  describe "text values" do
    let(:worded) do
      create_scene_template(slots: [scene_slot(key: "fridge")],
                            text_slots: [scene_text_slot(key: "headline", max_chars: 12, default: "Core AAC")])
    end

    def worded_composition(text_values)
      described_class.new(owner: printable, scene_template: worded, text_values: text_values)
    end

    it "accepts words within max_chars" do
      expect(worded_composition("headline" => "Core Words")).to be_valid
    end

    it "refuses words over max_chars" do
      composition = worded_composition("headline" => "Far too many words")

      expect(composition).not_to be_valid
      expect(composition.errors[:text_values].join).to include("18 characters is over the 12-character limit")
    end

    it "refuses a key the template has no text slot for" do
      composition = worded_composition("fridge" => "Hi")

      expect(composition).not_to be_valid
      expect(composition.errors[:text_values].join).to include("doesn't have (fridge)")
    end

    it "stores nothing for a blank value, so the slot falls back to its default" do
      composition = worded_composition("headline" => "   ")
      composition.valid?

      expect(composition.text_values).to eq({})
      expect(composition.resolved_text(worded.text_slot_for("headline"))).to eq("Core AAC")
    end

    it "squishes whitespace" do
      composition = worded_composition("headline" => "  Core \n Words ")
      composition.valid?

      expect(composition.text_values).to eq("headline" => "Core Words")
    end

    it "changes the render digest when the words change" do
      composition = described_class.create!(owner: printable, scene_template: worded, text_values: { "headline" => "Core" })
      before = composition.current_render_digest
      composition.update!(text_values: { "headline" => "Feelings" })

      expect(composition.current_render_digest).not_to eq(before)
    end

    it "changes the render digest when the facts an overlay quotes change" do
      template = create_scene_template(overlay_regions: [scene_overlay])
      composition = described_class.create!(owner: printable, scene_template: template)
      before = composition.current_render_digest

      printable.update!(board_ids: [board.id])

      expect(described_class.find(composition.id).current_render_digest).not_to eq(before)
    end
  end

  describe "#attach_render!" do
    it "attaches a JPEG at a versioned key and stamps the render" do
      composition = described_class.create!(owner: printable, scene_template: template)
      composition.update_columns(error: "old failure")

      composition.attach_render!(bytes: "jpeg-bytes", digest: "abc")
      composition.reload

      expect(composition.render.blob.content_type).to eq("image/jpeg")
      expect(composition.render.blob.key).to start_with("scene_compositions/#{composition.id}/")
      expect(composition.render_digest).to eq("abc")
      expect(composition.rendered_at).to be_present
      expect(composition.error).to be_nil
    end
  end

  describe "#attach_slot_upload!" do
    let(:composition) { described_class.create!(owner: printable, scene_template: template) }

    it "refuses a format outside the allowlist" do
      expect {
        composition.attach_slot_upload!(io: StringIO.new("<svg/>"), filename: "x.svg", content_type: "image/svg+xml")
      }.to raise_error(ArgumentError)
    end

    it "refuses a picture over the size cap" do
      big = StringIO.new("x" * (described_class::MAX_UPLOAD_BYTES + 1))

      expect {
        composition.attach_slot_upload!(io: big, filename: "big.png", content_type: "image/png")
      }.to raise_error(ArgumentError, /under 10 MB/)
    end

    it "prunes uploads no slot points at any more" do
      kept = composition.attach_slot_upload!(io: StringIO.new(scene_png), filename: "kept.png", content_type: "image/png")
      composition.attach_slot_upload!(io: StringIO.new(scene_png), filename: "dropped.png", content_type: "image/png")
      composition.update!(slot_art: { "fridge" => { "source" => "upload", "blob_id" => kept.id } })

      composition.prune_unused_uploads!

      expect(composition.reload.slot_uploads.map(&:blob_id)).to eq([kept.id])
    end
  end

  it "enqueues its render" do
    composition = described_class.create!(owner: printable, scene_template: template)
    allow(RenderSceneCompositionJob).to receive(:perform_async)

    composition.enqueue_render!

    expect(RenderSceneCompositionJob).to have_received(:perform_async).with(composition.id)
  end

  it "is destroyed with its printable" do
    composition = described_class.create!(owner: printable, scene_template: template)

    printable.destroy!

    expect(described_class.exists?(composition.id)).to be(false)
  end
end
