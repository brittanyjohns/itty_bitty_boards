require "rails_helper"

RSpec.describe SceneTemplate, type: :model do
  describe "base image" do
    it "reads its pixel size from the upload, which is the space every quad is in" do
      template = build_scene_template(width: 640, height: 480, slots: [])

      expect([template.width, template.height]).to eq([640, 480])
    end

    it "is required" do
      template = described_class.new(slug: "no-base", name: "No base", slots: [])

      expect(template).not_to be_valid
      expect(template.errors[:base_image]).to be_present
    end

    it "refuses a format outside the allowlist" do
      template = described_class.new(slug: "svg", name: "SVG")

      expect {
        template.assign_base_image(io: StringIO.new("<svg/>"), filename: "x.svg", content_type: "image/svg+xml")
      }.to raise_error(ArgumentError, /image\/svg\+xml/)
    end

    it "uploads to a versioned key, so a replaced image is never served from a CDN cache" do
      template = create_scene_template

      expect(template.base_image.blob.key).to match(%r{\Ascene_templates/\h{16}/base\.png\z})
    end
  end

  describe "slot validation" do
    it "accepts a clockwise, convex quad inside the image" do
      expect(build_scene_template).to be_valid
    end

    it "refuses a corner outside the base image" do
      template = build_scene_template(slots: [scene_slot(quad: [[40, 40], [460, 40], [460, 200], [40, 200]])])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("inside the 400x300")
    end

    it "refuses collinear corners using the homography's own degeneracy check" do
      template = build_scene_template(slots: [scene_slot(quad: [[10, 10], [50, 10], [90, 10], [130, 10]])])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("collinear")
    end

    # Both solve to a valid matrix, so neither would fail a render — they would
    # ship folded or mirrored art.
    it "refuses corners given counter-clockwise" do
      template = build_scene_template(slots: [scene_slot(quad: [[40, 40], [40, 200], [160, 200], [160, 40]])])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("clockwise")
    end

    it "refuses a bow-tie quad" do
      template = build_scene_template(slots: [scene_slot(quad: [[40, 40], [160, 40], [40, 200], [160, 200]])])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("clockwise")
    end

    it "refuses duplicate slot keys" do
      template = build_scene_template(slots: [
        scene_slot(key: "sheet"),
        scene_slot(key: "sheet", quad: [[200, 40], [320, 40], [320, 200], [200, 200]]),
      ])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("duplicate keys: sheet")
    end

    # Same guard paper_scene_spec keeps for the vendored scenes: a slot filed
    # under the wrong orientation is a filter that lies.
    it "refuses a portrait slot whose quad is landscape" do
      template = build_scene_template(slots: [scene_slot(orientation: "portrait", quad: [[40, 40], [300, 40], [300, 120], [40, 120]])])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("can't be portrait")
    end

    it "refuses a landscape slot whose quad is portrait" do
      template = build_scene_template(slots: [scene_slot(orientation: "landscape")])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("can't be landscape")
    end

    it "refuses an art source it doesn't know" do
      template = build_scene_template(slots: [scene_slot(accepts: %w[upload ai_generated])])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("ai_generated")
    end

    it "refuses an unknown kind and finish" do
      template = build_scene_template(slots: [scene_slot(kind: "poster", finish: "sparkle")])

      expect(template).not_to be_valid
      expect(template.errors[:slots].join).to include("kind must be", "finish must be")
    end

    it "normalizes form strings into numbers and fills defaults by kind" do
      template = build_scene_template(slots: [{ "key" => "screen", "kind" => "tablet",
                                                "quad" => [%w[40 40], %w[300 40], %w[300 200], %w[40 200]] }])
      template.valid?

      slot = template.slots.first
      expect(slot["quad"]).to eq([[40, 40], [300, 40], [300, 200], [40, 200]])
      expect(slot["finish"]).to eq("glare")
      expect(slot["orientation"]).to eq("any")
      expect(slot["accepts"]).to eq(Boards::Printables::SceneSlot::ACCEPTS)
      expect(template).to be_valid
    end

    it "refuses a front layer that isn't the base image's size" do
      template = build_scene_template
      template.assign_front_layer(io: StringIO.new(scene_png(200, 150)), filename: "front.png", content_type: "image/png")

      expect(template).not_to be_valid
      expect(template.errors[:front_layer].join).to include("200x150")
    end
  end

  describe "status" do
    it "can't be calibrated without a slot" do
      template = build_scene_template(slots: [], status: "calibrated")

      expect(template).not_to be_valid
      expect(template.errors[:status]).to be_present
    end

    it "can be a draft without one" do
      expect(build_scene_template(slots: [], status: "draft")).to be_valid
    end
  end

  describe "calibration_version" do
    it "starts at zero" do
      expect(create_scene_template.calibration_version).to eq(0)
    end

    it "bumps when the slots change" do
      template = create_scene_template
      template.update!(slots: [scene_slot(quad: [[41, 40], [160, 40], [160, 200], [40, 200]])])

      expect(template.reload.calibration_version).to eq(1)
    end

    it "does not bump for a rename or a no-op slot save" do
      template = create_scene_template
      template.update!(name: "Renamed", slots: template.slots.deep_dup)

      expect(template.reload.calibration_version).to eq(0)
    end

    it "bumps when a front layer is added" do
      template = create_scene_template
      template.assign_front_layer(io: StringIO.new(scene_png(400, 300, ChunkyPNG::Color::TRANSPARENT)),
                                  filename: "front.png", content_type: "image/png")
      template.save!

      expect(template.reload.calibration_version).to eq(1)
      expect(template.front_layer).to be_attached
    end
  end

  describe "text slots" do
    def template_with(*text_slots, slots: [scene_slot])
      build_scene_template(slots: slots, text_slots: text_slots)
    end

    def text_errors(template)
      template.valid?
      template.errors[:text_slots].join(" | ")
    end

    it "accepts a text slot inside the image in an allowlisted font" do
      expect(template_with(scene_text_slot)).to be_valid
    end

    it "normalizes form strings, drops unknown keys and fills defaults by font" do
      template = template_with({ "key" => "note", "box" => %w[10 20 200 40], "font" => "Caveat", "color" => "#ABCDEF",
                                 "max_px" => "40", "min_px" => "12", "max_chars" => "30", "onclick" => "x" })
      template.valid?

      expect(template.text_slots.first).to eq(
        "key" => "note", "label" => "Note", "box" => [10, 20, 200, 40], "rotation" => 0, "font" => "caveat",
        "weight" => 700, "color" => "#abcdef", "align" => "center", "max_px" => 40, "min_px" => 12,
        "max_chars" => 30, "default" => "",
      )
      expect(template).to be_valid
    end

    it "refuses a box outside the base image" do
      expect(text_errors(template_with(scene_text_slot(box: [300, 250, 200, 80])))).to include("inside the 400x300")
    end

    it "refuses a font that isn't on the list" do
      expect(text_errors(template_with(scene_text_slot(font: "comic-sans")))).to include("font must be one of nunito, fredoka, caveat")
    end

    it "refuses a weight the font's vendored file doesn't carry" do
      expect(text_errors(template_with(scene_text_slot(font: "fredoka", weight: 800)))).to include("weight for fredoka")
    end

    it "refuses a colour that isn't a hex" do
      expect(text_errors(template_with(scene_text_slot(color: "red; background: url(x)")))).to include("hex colour")
    end

    it "refuses min_px larger than max_px" do
      expect(text_errors(template_with(scene_text_slot(min_px: 50, max_px: 40)))).to include("min_px (50) can't be larger than max_px (40)")
    end

    it "refuses a default longer than max_chars" do
      expect(text_errors(template_with(scene_text_slot(max_chars: 5, default: "Too long")))).to include("longer than max_chars")
    end

    it "refuses a key a slot already uses" do
      expect(text_errors(template_with(scene_text_slot(key: "fridge")))).to include("unique across slots, text slots and overlays: fridge")
    end
  end

  describe "overlay regions" do
    it "accepts an allowlisted partial in a box inside the image" do
      expect(build_scene_template(overlay_regions: [scene_overlay])).to be_valid
    end

    it "refuses a partial that isn't on the allowlist" do
      template = build_scene_template(overlay_regions: [scene_overlay(partial: "free_text")])

      expect(template).not_to be_valid
      expect(template.errors[:overlay_regions].join).to include("partial must be one of feature_list, badges, steps_row, check_pills")
    end

    it "refuses a box outside the base image" do
      template = build_scene_template(overlay_regions: [scene_overlay(box: [0, 0, 401, 10])])

      expect(template).not_to be_valid
      expect(template.errors[:overlay_regions].join).to include("inside the 400x300")
    end

    it "refuses a key a text slot already uses" do
      template = build_scene_template(text_slots: [scene_text_slot(key: "same")], overlay_regions: [scene_overlay(key: "same")])

      expect(template).not_to be_valid
      expect(template.errors[:text_slots].join).to include("unique across")
    end
  end

  describe "calibration_version and the text layers" do
    it "bumps when a text slot changes" do
      template = create_scene_template(text_slots: [scene_text_slot])
      template.update!(text_slots: [scene_text_slot(color: "#e589b3")])

      expect(template.reload.calibration_version).to eq(1)
    end

    it "bumps when an overlay is added" do
      template = create_scene_template
      template.update!(overlay_regions: [scene_overlay])

      expect(template.reload.calibration_version).to eq(1)
    end

    it "does not bump for a no-op text save" do
      template = create_scene_template(text_slots: [scene_text_slot], overlay_regions: [scene_overlay])
      template.update!(text_slots: template.text_slots.deep_dup, overlay_regions: template.overlay_regions.deep_dup)

      expect(template.reload.calibration_version).to eq(0)
    end
  end

  describe "#retire!" do
    let(:owner) { create(:user) }
    let(:board) { create(:board, user: owner) }
    let(:printable) { BoardPrintable.create!(board: board, status: "complete", board_ids: [board.id]) }

    it "destroys a template nothing uses" do
      template = create_scene_template

      expect(template.retire!).to eq(:destroyed)
      expect(described_class.exists?(template.id)).to be(false)
    end

    it "archives a template a composition still renders from" do
      template = create_scene_template
      SceneComposition.create!(owner: printable, scene_template: template)

      expect(template.retire!).to eq(:archived)
      expect(template.reload).to be_archived
    end

    it "can't be destroyed out from under a composition" do
      template = create_scene_template
      SceneComposition.create!(owner: printable, scene_template: template)

      expect(template.destroy).to be(false)
    end
  end
end
