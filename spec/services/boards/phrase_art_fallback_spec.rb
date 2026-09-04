require "rails_helper"

# `Image.by_label` matches a whole label exactly, so a phrase either has a
# library row of its own or it has nothing — nothing in the resolver chain
# decomposes one. On a generated circle-time board that meant `I feel happy`
# and `I feel sad` resolved to real art while `I feel tired`, built
# identically, rendered as an inline data:image/svg+xml of its own text: a
# visibly emptier tile on screen and a blank square on the laminated print.
RSpec.describe Boards::PhraseArtFallback do
  describe ".head_word" do
    it "takes the last word that carries meaning" do
      expect(described_class.head_word("I feel tired")).to eq("tired")
      expect(described_class.head_word("my turn")).to eq("turn")
      expect(described_class.head_word("Good morning")).to eq("morning")
      expect(described_class.head_word("song please")).to eq("song")
      expect(described_class.head_word("All done")).to eq("done")
    end

    it "has no head word for a single word — there is nothing to fall back to" do
      expect(described_class.head_word("tired")).to be_nil
      expect(described_class.head_word("")).to be_nil
      expect(described_class.head_word(nil)).to be_nil
    end

    # A bad picture on an AAC tile is worse than none: the picture is what a
    # nonspeaking user reads.
    it "answers nil rather than guessing when every word is a function word" do
      expect(described_class.head_word("how are you")).to be_nil
    end
  end

  describe ".art_for" do
    let(:user) { create(:user) }

    it "returns the head word's tile art" do
      tired = create(:image, label: "tired", is_private: false)
      allow_any_instance_of(Image).to receive(:display_tile_url).and_return("https://cdn/tired.png")

      expect(described_class.art_for("I feel tired", user: user)).to eq("https://cdn/tired.png")
      expect(tired.reload.label).to eq("tired")
    end

    it "returns nil when the head word has no art of its own" do
      create(:image, label: "tired", is_private: false)
      allow_any_instance_of(Image).to receive(:display_tile_url).and_return(nil)

      expect(described_class.art_for("I feel tired", user: user)).to be_nil
    end

    it "never creates a library row for a head word it could not find" do
      expect { described_class.art_for("I feel bewildered", user: user) }
        .not_to change(Image, :count)
    end
  end
end
