require "rails_helper"

# `Board.create_slug` is the one place a board name becomes a URL key. It has to
# strip the "copy" markers a duplicated board carries in its name, because the
# slug outlives the name: it is what `/pb/<slug>` resolves through.
RSpec.describe Board, ".create_slug" do
  describe "copy markers" do
    # The API/admin clone path names duplicates "Copy of X"; CloneBoardModal on
    # the frontend pre-fills "X Copy". Both have to collapse to the same slug.
    {
      "Snack Time" => "snack-time",
      "Copy of Snack Time" => "snack-time",
      "copy-of-Snack Time" => "snack-time",
      "COPY OF Snack Time" => "snack-time",
      "Snack Time Copy" => "snack-time",
      "Snack Time copy" => "snack-time",
      "Snack Time - Copy" => "snack-time",
      "Snack Time (Copy)" => "snack-time",
      "Snack Time [copy]" => "snack-time",
      "Snack Time copy 2" => "snack-time",
      "Snack Time Copy Copy" => "snack-time",
      "Copy of Copy of Snack Time" => "snack-time",
      "Feelings & Emotions Copy" => "feelings-emotions",
    }.each do |name, expected|
      it "slugifies #{name.inspect} to #{expected.inspect}" do
        expect(described_class.create_slug(name)).to eq(expected)
      end
    end
  end

  describe "names that only look like copies" do
    # The trailing marker requires a separator before "copy", so a word that
    # merely ENDS in those letters keeps them.
    it "leaves a word ending in -copy alone" do
      expect(described_class.create_slug("Photocopy Board")).to eq("photocopy-board")
      expect(described_class.create_slug("Photocopy")).to eq("photocopy")
    end

    it "leaves 'copy' in the middle of a name alone" do
      expect(described_class.create_slug("My Copy Board")).to eq("my-copy-board")
    end
  end

  describe "when stripping would empty the name" do
    # `slug` is `default: ""` with a non-allow_blank uniqueness validation, so a
    # blank slug collides with the first slug-less row and the save fails.
    # Falling back to the un-stripped name is the safe answer.
    it "falls back to the un-stripped name rather than returning blank" do
      expect(described_class.create_slug("Copy")).to eq("copy")
      expect(described_class.create_slug("copy")).to eq("copy")
    end
  end

  describe "#generate_unique_slug" do
    let(:user) { create(:user) }

    it "derives from the name with copy markers stripped" do
      board = build(:board, user: user, name: "Snack Time Copy", slug: nil)
      expect(board.generate_unique_slug).to eq("snack-time")
    end

    it "suffixes on collision instead of reusing a taken slug" do
      create(:board, user: user, slug: "snack-time")
      board = build(:board, user: user, name: "Snack Time Copy", slug: nil)

      expect(board.generate_unique_slug).to match(/\Asnack-time-[0-9a-f]{8}\z/)
    end
  end
end
