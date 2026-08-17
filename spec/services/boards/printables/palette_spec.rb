require "rails_helper"

RSpec.describe Boards::Printables::Palette do
  let(:owner) { create(:user) }

  def board(slug) = build(:board, user: owner, slug: slug)

  # A listing is already live by the time anyone regenerates its images. A
  # random pick would hand a published Etsy listing a different look every time.
  it "picks the same palette for a board every time" do
    picks = Array.new(5) { described_class.for(board("core-words")).key }

    expect(picks.uniq.size).to eq(1)
  end

  it "spreads different boards across the pool rather than favouring one" do
    keys = Array.new(40) { |i| described_class.for(board("board-#{i}")).key }

    expect(keys.uniq.size).to be > 1
  end

  # Hashing the same key for both would pair scene 1 with palette 1 forever and
  # collapse 4 x 5 possible looks back down to 4.
  it "rotates independently of the room scene" do
    boards = Array.new(40) { |i| board("board-#{i}") }

    pairs = boards.map do |b|
      [Boards::Printables::BrandAssets.scene_name_for(b), described_class.for(b).key]
    end

    expect(pairs.uniq.size).to be > described_class::PALETTES.size
  end

  # The property the modulo pick did not have, and the reason it was replaced:
  # appending a palette must not reshuffle the boards already using the others.
  it "leaves most boards where they were when a palette is appended" do
    boards = Array.new(60) { |i| board("board-#{i}") }
    before = boards.map { |b| described_class.for(b).key }

    grown = described_class::PALETTES + [described_class::PALETTES.first.merge(key: "brand-new")]
    stub_const("#{described_class}::PALETTES", grown)
    after = boards.map { |b| described_class.for(b).key }

    unchanged = before.zip(after).count { |was, now| was == now }
    # Only boards that land on the new palette may move; nothing else does.
    expect(unchanged).to eq(after.count { |key| key != "brand-new" })
    expect(after).to include("brand-new")
  end

  # Order carried meaning under the modulo pick. It must not any more, or the
  # next person to tidy this list re-skins the whole shop.
  it "is unaffected by the order of the list" do
    boards = Array.new(30) { |i| board("board-#{i}") }
    before = boards.map { |b| described_class.for(b).key }

    stub_const("#{described_class}::PALETTES", described_class::PALETTES.reverse)

    expect(boards.map { |b| described_class.for(b).key }).to eq(before)
  end

  describe "#css_vars" do
    it "overrides every token the layout leaves rotatable" do
      css = described_class.for(board("core-words")).css_vars

      expect(css).to include("--accent:", "--accent-soft:", "--band:", "--surface:")
      expect(css).to match(/\A:root \{/)
    end
  end

  # These carry the contrast on every slide. A palette that can move them is a
  # palette that can ship an unreadable listing image.
  it "never rotates the navy, the white paper or the black ribbon" do
    values = described_class::PALETTES.flat_map { |p| p.values_at(:accent_soft, :band) }

    expect(values).not_to include("#FFFFFF", "#1A1A1A")
  end
end
