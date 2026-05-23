require "rails_helper"

RSpec.describe TranslateImageJob, type: :job do
  let(:image) { FactoryBot.create(:image, label: "hello") }

  it "skips when image is missing" do
    expect_any_instance_of(Image).not_to receive(:translate_to)
    described_class.new.perform(0, "es")
  end

  it "skips when language is blank" do
    expect_any_instance_of(Image).not_to receive(:translate_to)
    described_class.new.perform(image.id, "")
  end

  it "skips when language is 'en'" do
    expect_any_instance_of(Image).not_to receive(:translate_to)
    described_class.new.perform(image.id, "en")
  end

  it "skips when language is unsupported" do
    expect_any_instance_of(Image).not_to receive(:translate_to)
    described_class.new.perform(image.id, "xx")
  end

  it "skips when translation already exists" do
    image.update!(language_settings: { "es" => { "label" => "hola" } })
    expect_any_instance_of(Image).not_to receive(:translate_to)
    described_class.new.perform(image.id, "es")
  end

  it "calls translate_to and saves when translation is missing" do
    allow(Image).to receive(:find_by).with(id: image.id).and_return(image)
    expect(image).to receive(:translate_to).with("es").and_return("hola")
    expect(image).to receive(:save!)
    allow(CreateAllAudioJob).to receive(:perform_async)
    described_class.new.perform(image.id, "es")
  end

  it "enqueues localized audio generation after translating" do
    allow(Image).to receive(:find_by).with(id: image.id).and_return(image)
    allow(image).to receive(:translate_to).and_return("hola")
    allow(image).to receive(:save!)
    expect(CreateAllAudioJob).to receive(:perform_async).with(image.id, "es", "select")
    described_class.new.perform(image.id, "es")
  end

  it "does not enqueue audio when translation is skipped" do
    image.update!(language_settings: { "es" => { "label" => "hola" } })
    expect(CreateAllAudioJob).not_to receive(:perform_async)
    described_class.new.perform(image.id, "es")
  end
end
