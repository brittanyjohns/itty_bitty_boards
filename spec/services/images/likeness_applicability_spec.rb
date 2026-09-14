require "rails_helper"

# A likeness is drawn only onto a picture whose person IS the communicator.
# Adding it to every prompt made the image model put the communicator into
# "dog", and draw "she" / "girl" as a boy who looks like them.
RSpec.describe Images::LikenessApplicability do
  def applies?(label, pos = nil, user_input: nil)
    described_class.applies?(label: label, part_of_speech: pos, user_input: user_input)
  end

  [
    ["she", "pronoun"],
    ["her", "pronoun"],
    ["he", "pronoun"],
    ["you", "pronoun"],
    ["we", "pronoun"],
    ["girl", "noun"],
    ["boy", "noun"],
    ["mom", "noun"],
    ["dog", "noun"],
    ["apple", "noun"],
    ["big", "adjective"],
    ["red", "adjective"],
    ["in", "preposition"],
    ["that", "determiner"],
    ["she is happy", "adjective"],
    ["me and mom", nil],
    ["hug mom", "verb"],
    ["slowly", "adverb"],
    ["kite", nil],
  ].each do |label, pos|
    it "does not draw the communicator for #{label.inspect} (#{pos.inspect})" do
      expect(applies?(label, pos)).to be(false)
    end
  end

  [
    ["I", "pronoun"],
    ["me", "pronoun"],
    ["my turn", nil],
    ["I feel tired", nil],
    ["I'm hungry", nil],
    ["eat", "verb"],
    ["run", "verb"],
    ["happy", "adjective"],
    ["scared", "adjective"],
    ["hi", "social"],
    ["thank you", "social"],
    ["stop", "important_function"],
    ["what", "question"],
  ].each do |label, pos|
    it "draws the communicator for #{label.inspect} (#{pos.inspect})" do
      expect(applies?(label, pos)).to be(true)
    end
  end

  it "reads a typed description as well as the label" do
    expect(applies?("feed", "verb", user_input: "a girl feeding a dog")).to be(false)
    expect(applies?("feed", "verb", user_input: "feeding my fish")).to be(true)
  end

  it "is case- and punctuation-insensitive" do
    expect(applies?("SHE!", "pronoun")).to be(false)
    expect(applies?("Thank you!", "social")).to be(true)
  end
end
