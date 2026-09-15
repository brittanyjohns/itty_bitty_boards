require "rails_helper"

RSpec.describe Scenes::GenerateTemplate do
  let(:template) do
    SceneTemplate.create!(
      name: "Kitchen",
      slug: "kitchen-#{SecureRandom.hex(3)}",
      category: "board",
      source: "ai",
      status: SceneTemplate::STATUS_DRAFT,
      generation: {
        "state" => SceneTemplate::GENERATION_RUNNING,
        "kind" => SceneTemplate::GENERATION_KIND_AI,
        "request" => {
          "description" => "A sunny kitchen with a white fridge and a tablet on the counter",
          "slot_hints" => "one sheet on the fridge; the tablet screen",
          "orientation" => "landscape",
        },
      },
    )
  end

  describe ".build_prompt" do
    it "carries the description, every magenta rule and the no-text rule" do
      prompt = described_class.build_prompt(description: "A classroom easel", slot_hints: "sheet on the easel",
                                            orientation: "portrait")

      expect(prompt).to include("A classroom easel", "sheet on the easel", "photorealistic", "tall portrait frame")
      described_class::MAGENTA_RULES.each { |rule| expect(prompt).to include(rule) }
      expect(prompt).to include("#FF00FF", described_class::NO_TEXT_RULE)
    end

    it "refuses a blank description" do
      expect { described_class.build_prompt(description: "  ") }.to raise_error(ArgumentError)
    end

    it "strips the admin-only raw-prompt marker and control characters" do
      prompt = described_class.build_prompt(description: "[[REPLACE_LABEL]] a desk\nwith a lamp")
      expect(prompt).not_to include("[[")
      expect(prompt).to include("a desk with a lamp")
    end
  end

  describe "#call" do
    let(:captured) { {} }
    let(:images_api) { double("images") }
    let(:edit_client) { double("openai_client", images: images_api) }
    let(:board) { create(:board, name: "Secret Core Words Board") }

    before do
      allow(AppEnv).to receive(:staging?).and_return(false)
      allow(OpenAiClient).to receive(:new) do |opts|
        captured[:opts] = opts
        double("image_client", create_image: {
          b64_json: Base64.strict_encode64(magenta_scene_png),
          content_type: "image/png",
          output_format: "png",
          model: "gpt-image-1-mini",
          size: opts[:size],
          quality: opts[:quality],
        })
      end
      allow(images_api).to receive(:edit) do |parameters:|
        captured[:edit_image] = File.binread(parameters[:image])
        edited = ChunkyPNG::Image.new(200, 150, ChunkyPNG::Color::WHITE).to_blob
        { "data" => [{ "b64_json" => Base64.strict_encode64(edited) }] }
      end
    end

    it "sends only the scene prompt, at the orientation's size, as a PNG" do
      board
      described_class.new(template, edit_client: edit_client).call

      opts = captured[:opts]
      expect(opts.keys).to match_array(%i[prompt size output_format quality model request_timeout])
      expect(opts).to include(size: "1536x1024", output_format: "png", quality: described_class.quality)
      described_class::MAGENTA_RULES.each { |rule| expect(opts[:prompt]).to include(rule) }
      expect(opts[:prompt]).not_to include(board.name)
      expect(template.reload.prompt).to eq(opts[:prompt])
    end

    it "sends the edit only the scene the model itself drew" do
      described_class.new(template, edit_client: edit_client).call

      expect(ChunkyPNG::Image.from_blob(captured[:edit_image]).pixels).to eq(magenta_scene.pixels)
    end

    it "builds a draft template: source image, detected slots, front layer and a blanked base" do
      described_class.new(template, edit_client: edit_client).call
      template.reload

      expect(template).to be_draft
      expect(template.source).to eq("ai")
      expect(template.slots.size).to eq(2)
      expect(template.source_image).to be_attached
      expect(template.base_image).to be_attached
      expect(template.front_layer).to be_attached
      expect([template.width, template.height]).to eq([200, 150])
      expect(template.generation).to include("state" => "complete", "detected_slots" => 2, "inpainted" => true)
      expect(template.generation["image"]).to include("model" => "gpt-image-1-mini", "size" => "1536x1024")

      base = ChunkyPNG::Image.from_blob(template.base_image.download)
      expect(base.get_pixel(30, 60)).to eq(ChunkyPNG::Color::WHITE)
    end

    context "on staging" do
      before do
        allow(AppEnv).to receive(:staging?).and_return(true)
        allow(OpenAiClient).to receive(:new).and_call_original
      end

      it "makes no OpenAI call and records a clear note instead of raising" do
        expect(OpenAI::Client).not_to receive(:new)
        expect(images_api).not_to receive(:edit)

        described_class.new(template, edit_client: edit_client).call
        template.reload

        expect(template.generation["state"]).to eq("failed")
        expect(template.generation["error"]).to eq(Scenes::BuildFromMarkedImage::NO_SLOTS_ERROR)
        expect(template.generation["notes"]).to include(described_class::STAGING_NOTE)
        expect(template.notes).to include("No magenta placeholder surfaces were found")
        expect(template.slots).to eq([])
        expect(template.base_image).to be_attached
      end
    end
  end
end
