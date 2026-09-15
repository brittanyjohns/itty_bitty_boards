require "rails_helper"

RSpec.describe Scenes::BuildFromMarkedImage do
  let(:template) do
    SceneTemplate.create!(
      name: "Fridge", slug: "fridge-#{SecureRandom.hex(3)}", category: "board", source: "canva",
      status: SceneTemplate::STATUS_DRAFT,
      generation: { "state" => SceneTemplate::GENERATION_RUNNING, "kind" => SceneTemplate::GENERATION_KIND_UPLOAD },
    )
  end

  def build(bytes: magenta_scene_png, content_type: "image/png")
    described_class.new(template: template, bytes: bytes, content_type: content_type, inpaint: false).call
  end

  it "detects the slots and extracts a front layer with no OpenAI call (the upload path)" do
    expect(OpenAI::Client).not_to receive(:new)

    build
    template.reload

    expect(template.slots.map { |slot| slot["key"] }).to eq(%w[slot1 slot2])
    expect(template.front_layer).to be_attached
    expect(template.generation).to include("state" => "complete", "detected_slots" => 2, "inpainted" => false)
    expect(template.generation["notes"]).to include(described_class::FALLBACK_BASE_NOTE)
    expect(template.notes).to include("pink fringe")
  end

  it "keeps the magenta in an upload's base image" do
    build
    base = ChunkyPNG::Image.from_blob(template.reload.base_image.download)
    expect(base.get_pixel(30, 60)).to eq(MagentaSceneHelpers::MAGENTA)
  end

  it "converts a non-PNG scene before detecting" do
    require "vips"
    jpeg = Vips::Image.new_from_buffer(magenta_scene_png, "").write_to_buffer(".jpg", Q: 95)

    build(bytes: jpeg, content_type: "image/jpeg")

    expect(template.reload.slots.size).to eq(2)
  end

  it "hands slots the model refuses to the calibrator unsaved, and still saves the image" do
    bad = SceneTemplate.normalize_slot("key" => "Bad Key!", "quad" => MagentaSceneHelpers::SHEET_QUAD)
    allow_any_instance_of(Scenes::SlotDetector).to receive(:call).and_return([bad])

    build
    template.reload

    expect(template.slots).to eq([])
    expect(template.calibrator_slots).to eq([bad])
    expect(template.generation["slot_errors"].join).to include("key must be")
    expect(template.base_image).to be_attached
  end
end
