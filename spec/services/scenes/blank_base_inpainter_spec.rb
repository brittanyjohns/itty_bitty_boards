require "rails_helper"

RSpec.describe Scenes::BlankBaseInpainter do
  let(:scene) { magenta_scene }
  let(:green) { ChunkyPNG::Color.rgb(0, 200, 0) }
  let(:edited_png) { ChunkyPNG::Image.new(scene.width, scene.height, green).to_blob }
  let(:sent) { {} }
  let(:images_api) { double("images") }
  let(:client) { double("openai_client", images: images_api) }

  before do
    allow(AppEnv).to receive(:staging?).and_return(false)
    allow(images_api).to receive(:edit) do |parameters:|
      sent[:parameters] = parameters
      sent[:image] = ChunkyPNG::Image.from_blob(File.binread(parameters[:image]))
      sent[:mask] = ChunkyPNG::Image.from_blob(File.binread(parameters[:mask]))
      { "data" => [{ "b64_json" => Base64.strict_encode64(edited_png) }] }
    end
  end

  subject(:inpainter) { described_class.new(scene, client: client) }

  it "sends the scene and a mask that is transparent over the dilated magenta" do
    result = inpainter.call

    expect(result.inpainted).to be(true)
    expect(sent[:parameters]).to include(prompt: described_class::PROMPT, size: "auto")
    expect(sent[:image].pixels).to eq(scene.pixels)
    expect(ChunkyPNG::Color.a(sent[:mask].get_pixel(30, 60))).to eq(0)   # magenta
    expect(ChunkyPNG::Color.a(sent[:mask].get_pixel(17, 60))).to eq(0)   # within the 4px dilation
    expect(ChunkyPNG::Color.a(sent[:mask].get_pixel(10, 60))).to eq(255) # beyond it
  end

  it "copies the edit back only inside the mask; every other pixel is byte-identical" do
    selection = inpainter.selected_indices.to_set
    out = inpainter.call.image

    out.pixels.each_with_index do |pixel, index|
      if selection.include?(index)
        expect(pixel).to eq(green)
      else
        expect(pixel).to eq(scene.pixels[index]), "pixel #{index} changed outside the mask"
      end
    end
    expect(out.get_pixel(5, 5)).to eq(MagentaSceneHelpers::SCENE_BG)
    expect(out.get_pixel(30, 60)).to eq(green)
  end

  it "limits the mask to the regions it is given" do
    only_sheet = described_class.new(scene, regions: [[20, 20, 79, 109]], client: client)
    indices = only_sheet.selected_indices
    xs = indices.map { |i| i % scene.width }

    expect(xs.max).to be < 100
    expect(indices).to include((60 * scene.width) + 30)
  end

  it "falls back to the untouched scene when the call fails" do
    allow(images_api).to receive(:edit).and_raise(Faraday::ServerError, "boom")

    result = inpainter.call

    expect(result.inpainted).to be(false)
    expect(result.image).to equal(scene)
    expect(result.note).to include("failed")
  end

  it "falls back without a call on staging" do
    allow(AppEnv).to receive(:staging?).and_return(true)
    expect(images_api).not_to receive(:edit)

    result = inpainter.call

    expect(result.inpainted).to be(false)
    expect(result.note).to include("Staging")
  end

  it "falls back without a call when switched off" do
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("SCENE_INPAINT_ENABLED", "true").and_return("false")
    expect(images_api).not_to receive(:edit)

    expect(inpainter.call.inpainted).to be(false)
  end

  it "falls back when the edit returns no image" do
    allow(images_api).to receive(:edit).and_return({ "data" => [] })
    expect(inpainter.call.inpainted).to be(false)
  end
end
