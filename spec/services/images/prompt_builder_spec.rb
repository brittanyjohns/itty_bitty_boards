require "rails_helper"

RSpec.describe Images::PromptBuilder do
  def build(**opts)
    described_class.new(**{ label: "apple" }.merge(opts)).call
  end

  describe "the house envelope" do
    it "always forbids text, in concrete terms" do
      expect(build).to include("Do not include any text, letters, numbers")
    end

    it "always asks for a single centered subject" do
      expect(build).to include("Show a single subject, centered")
    end

    it "requests a transparent background by default" do
      expect(build).to include("background must be fully transparent")
    end

    it "requests a plain background when transparency is off" do
      result = build(transparent: false)
      expect(result).to include("plain, solid, uncluttered background")
      expect(result).not_to include("fully transparent")
    end
  end

  describe "styles" do
    it "defaults to the symbol style" do
      expect(described_class::DEFAULT_STYLE).to eq("symbol")
      expect(build).to include("flat vector AAC communication symbol")
    end

    it "uses the illustrated spec when asked" do
      result = build(style: "illustrated")
      expect(result).to include("simple, friendly illustration")
      expect(result).not_to include("flat vector AAC communication symbol")
    end

    it "falls back to the default for an unknown style rather than raising" do
      expect(build(style: "watercolor")).to include("flat vector AAC communication symbol")
    end
  end

  describe "subject handling" do
    it "uses the label when no user input is given" do
      expect(build).to include("representing 'apple'")
    end

    it "uses the user's description as the subject" do
      expect(build(user_input: "a red apple with a bite taken out"))
        .to include("representing 'a red apple with a bite taken out'")
    end

    # The frontend prefills the prompt field with the label, so "user input"
    # that just echoes the label is not really user input.
    it "treats an echoed label as no input" do
      expect(build(user_input: "Apple")).to include("representing 'apple'")
    end

    # This is the regression that mattered most: the old controller heuristic
    # passed any prompt longer than the label straight through to OpenAI with
    # no style spec and no constraints at all.
    it "wraps a long user prompt instead of passing it through" do
      long = "a photorealistic apple orchard at golden hour with a wooden ladder"
      result = build(user_input: long)

      expect(result).to include(long)
      expect(result).to include("flat vector AAC communication symbol")
      expect(result).to include("Do not include any text")
    end
  end

  describe "part-of-speech disambiguation" do
    it "asks for the action when the word is a verb" do
      expect(build(label: "can", part_of_speech: "verb"))
        .to include("Depict the action itself")
    end

    it "asks for the object when the word is a noun" do
      expect(build(part_of_speech: "noun")).to include("Depict the physical object")
    end

    it "adds nothing for categories with no useful visual instruction" do
      expect(build(part_of_speech: "conjunction")).not_to include("Depict")
    end

    it "adds nothing when the part of speech is unknown" do
      expect(build(part_of_speech: nil)).not_to include("Depict")
    end

    # The user's own words are more specific than a generic POS hint, and
    # stacking both produces contradictory instructions.
    it "defers to the user's description when one is given" do
      expect(build(user_input: "a tin can on a shelf", part_of_speech: "verb"))
        .not_to include("Depict the action itself")
    end
  end

  describe ".resolve_style" do
    it "prefers an explicit request value" do
      expect(described_class.resolve_style(requested: "illustrated")).to eq("illustrated")
    end

    it "falls back to the board setting" do
      board = build_stubbed(:board, settings: { "image_style" => "illustrated" })
      expect(described_class.resolve_style(board: board)).to eq("illustrated")
    end

    it "falls back to the user setting when the board has none" do
      user = build_stubbed(:user, settings: { "image_style" => "illustrated" })
      board = build_stubbed(:board, settings: {})
      expect(described_class.resolve_style(board: board, user: user)).to eq("illustrated")
    end

    it "lets the board override the user" do
      user = build_stubbed(:user, settings: { "image_style" => "illustrated" })
      board = build_stubbed(:board, settings: { "image_style" => "symbol" })
      expect(described_class.resolve_style(board: board, user: user)).to eq("symbol")
    end

    it "ignores an unknown stored value instead of raising" do
      user = build_stubbed(:user, settings: { "image_style" => "bogus" })
      expect(described_class.resolve_style(user: user)).to eq(described_class::DEFAULT_STYLE)
    end

    it "returns the default when nothing is set" do
      expect(described_class.resolve_style).to eq(described_class::DEFAULT_STYLE)
    end
  end

  describe ".for_image" do
    it "picks up the image's part of speech without the caller passing it" do
      image = build_stubbed(:image, label: "run", part_of_speech: "verb")
      expect(described_class.for_image(image)).to include("Depict the action itself")
    end
  end
end
