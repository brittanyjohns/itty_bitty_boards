require "rails_helper"

RSpec.describe CategorizeImageJob, type: :sidekiq do
  describe "#perform" do
    let(:image) do
      img = Image.new(label: "trampoline", user_id: nil)
      img.skip_categorize = true # avoid the synchronous categorize on create
      img.save!
      img
    end

    it "categorizes the image and sets part_of_speech + matching colors" do
      allow(AacWordCategorizer).to receive(:categorize).with("trampoline").and_return("noun")

      described_class.new.perform(image.id)

      image.reload
      expect(image.part_of_speech).to eq("noun")
      expect(image.bg_color).to eq(ColorHelper::PRESET_HEX["orange"]) # noun -> orange
      expect(image.text_color).to eq(image.text_color_for(image.bg_color))
    end

    it "does not re-trigger ensure_defaults (no categorize loop)" do
      allow(AacWordCategorizer).to receive(:categorize).with("trampoline").and_return("verb")

      # update_columns must not run callbacks, so categorize is called exactly
      # once by the job itself — not again via a before_save.
      described_class.new.perform(image.id)

      expect(AacWordCategorizer).to have_received(:categorize).once
    end

    it "is a no-op when the image no longer exists" do
      expect { described_class.new.perform(-1) }.not_to raise_error
    end
  end
end
