require "rails_helper"

RSpec.describe Images::PromptBuilder, "likeness layer" do
  let(:clause) { "If the picture shows a person, draw that person as a child with brown skin." }

  it "adds nothing without a likeness" do
    expect(described_class.new(label: "run", part_of_speech: "verb").call).not_to include("If the picture shows a person")
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

  it "composes the resolver result's clause in for_image" do
    image = build(:image, label: "wave", part_of_speech: "social")
    result = Images::LikenessResolver::Result.new(
      likeness: CommunicatorLikeness.from_hash("hair_style" => "curly"), age_band: "adult",
    )

    expect(described_class.for_image(image, likeness: result)).to include("draw that person as an adult with curly hair.")
  end
end
