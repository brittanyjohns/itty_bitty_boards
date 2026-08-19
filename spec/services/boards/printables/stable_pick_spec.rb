require "rails_helper"

RSpec.describe Boards::Printables::StablePick do
  let(:owner) { create(:user) }

  def board(slug) = build(:board, user: owner, slug: slug)

  let(:entries) { %w[alpha bravo charlie delta echo] }

  describe ".from" do
    it "picks the same entry for a board every time" do
      picks = Array.new(5) { described_class.from(entries, salt: "s", board: board("core-words")) }

      expect(picks.uniq.size).to eq(1)
    end

    # Rendezvous hashing scores each entry by its own name, so the list can be
    # reordered freely — the SLUG is the load-bearing thing, not the index.
    it "does not care what order the list is in" do
      b = board("core-words")

      expect(described_class.from(entries.reverse, salt: "s", board: b))
        .to eq(described_class.from(entries, salt: "s", board: b))
    end
  end

  describe ".top" do
    it "returns that many distinct entries, best first" do
      picked = described_class.top(entries, 2, salt: "s", board: board("core-words"))

      expect(picked.size).to eq(2)
      expect(picked.uniq.size).to eq(2)
    end

    it "leads with what .from picks, so a pair extends the single pick" do
      b = board("core-words")

      expect(described_class.top(entries, 2, salt: "s", board: b).first)
        .to eq(described_class.from(entries, salt: "s", board: b))
    end

    it "picks the same ranking every time" do
      rankings = Array.new(5) { described_class.top(entries, 3, salt: "s", board: board("core-words")) }

      expect(rankings.uniq.size).to eq(1)
    end

    it "does not care what order the list is in" do
      b = board("core-words")

      expect(described_class.top(entries.shuffle, 3, salt: "s", board: b))
        .to eq(described_class.top(entries, 3, salt: "s", board: b))
    end

    # The whole reason this is rendezvous hashing and not `sort % size`. Growing
    # the library must not re-skin every listing that already resolved.
    it "leaves most boards where they were when the list grows" do
      boards = Array.new(60) { |i| board("board-#{i}") }
      before = boards.map { |b| described_class.top(entries, 2, salt: "s", board: b) }
      after = boards.map { |b| described_class.top(entries + %w[foxtrot], 2, salt: "s", board: b) }

      unchanged = before.zip(after).count { |a, b| a == b }

      expect(unchanged).to be > (boards.size / 2)
    end

    # A pool shorter than the count is a scene library someone trimmed, not a
    # reason to fail a whole gallery render.
    it "returns what there is rather than raising on a short list" do
      expect(described_class.top(%w[only], 2, salt: "s", board: board("core-words"))).to eq(%w[only])
    end

    # Independent salts are what stop the scene, palette and tablet picks from
    # agreeing forever and collapsing the rotation.
    it "ranks differently under a different salt" do
      boards = Array.new(40) { |i| board("board-#{i}") }

      pairs = boards.map do |b|
        [described_class.top(entries, 1, salt: "a", board: b), described_class.top(entries, 1, salt: "b", board: b)]
      end

      expect(pairs.uniq.size).to be > entries.size
    end
  end
end
