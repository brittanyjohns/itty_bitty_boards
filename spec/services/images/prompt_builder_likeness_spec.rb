require "rails_helper"

RSpec.describe Images::PromptBuilder, "likeness layer" do
  let(:clause) { "Draw the person in this picture as a child with brown skin." }
  let(:result) do
    Images::LikenessResolver::Result.new(
      likeness: CommunicatorLikeness.from_hash("hair_style" => "curly"), age_band: "adult",
    )
  end

  it "adds nothing without a likeness" do
    expect(described_class.new(label: "run", part_of_speech: "verb").call).not_to include("Draw the person in this picture")
  end

  # After the part-of-speech clause (often what puts a person in the picture),
  # before modifiers and the style spec, so the house style stays last.
  it "sits between the part-of-speech clause and the modifiers" do
    prompt = described_class.new(label: "run", part_of_speech: "verb", modifiers: "thicker outlines",
                                 likeness_clause: clause).call

    pos_at = prompt.index("Depict the action itself")
    likeness_at = prompt.index(clause)
    modifiers_at = prompt.index("thicker outlines")
    style_at = prompt.index("flat vector AAC communication symbol")

    expect([pos_at, likeness_at, modifiers_at, style_at]).to all(be_present)
    expect(pos_at).to be < likeness_at
    expect(likeness_at).to be < modifiers_at
    expect(modifiers_at).to be < style_at
  end

  it "composes the resolver result's clause in for_image for a word whose picture is the communicator" do
    image = build(:image, label: "wave", part_of_speech: "social")

    expect(described_class.for_image(image, likeness: result)).to include("Draw the person in this picture as an adult with curly hair.")
  end

  # Gated here too, so no caller that passes a likeness can put the
  # communicator into a picture of something else.
  it "leaves the likeness out of for_image when the picture isn't the communicator" do
    %w[dog she girl].each do |label|
      image = build(:image, label: label, part_of_speech: label == "she" ? "pronoun" : "noun")

      expect(described_class.for_image(image, likeness: result)).not_to include("curly hair")
    end
  end
end
