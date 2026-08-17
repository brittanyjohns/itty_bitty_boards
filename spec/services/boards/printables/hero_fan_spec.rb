require "rails_helper"

RSpec.describe Boards::Printables::HeroFan do
  # The rule the layout used to state in a comment and nothing enforced. An
  # overflowing fan doesn't fail — it ships a listing image with half of the
  # outer page past the slide edge, which looks fine in the admin's thumbnail.
  describe "the closing rule" do
    described_class::GEOMETRY.each_key do |count|
      it "keeps #{count} cards inside the stage" do
        expect(described_class.build(count).coverage).to be <= described_class::MAX_COVERAGE
      end
    end

    it "refuses a geometry that would overflow rather than rendering it" do
      stub_const("#{described_class}::GEOMETRY", {3 => {width: 60.0, overlap: 5.0}})

      expect { described_class.build(3) }.to raise_error(described_class::OverflowError, /off the slide/)
    end
  end

  # RenderListingImages puts the ROOT board in the middle slot, so the middle
  # card is the one a buyer actually reads: it has to be the one drawn in front
  # and the one that isn't tilted.
  describe "the centre card" do
    it "is unrotated and on top for an odd count" do
      cards = described_class.build(5).cards

      expect(cards[2].rotation_deg).to eq(0.0)
      expect(cards.map(&:z_index).each_with_index.max_by(&:first).last).to eq(2)
    end

    it "splays the rest symmetrically around it" do
      rotations = described_class.build(5).cards.map(&:rotation_deg)

      expect(rotations).to eq(rotations.map(&:-@).reverse)
      expect(rotations.first).to be < 0
      expect(rotations.last).to be > 0
    end
  end

  it "gives every card a width, an overlap, a rotation and a z-index" do
    fan = described_class.build(4)

    expect(fan.css_width).to match(/\A\d+\.\d+%\z/)
    expect(fan.css_overlap).to match(/\A\d+\.\d+%\z/)
    expect(fan.cards.size).to eq(4)
    expect(fan.cards.map(&:z_index)).to all(be_positive)
  end

  # A single page uses .hero-stage.single and has no pile to arrange; asking for
  # a fan there is a caller bug, not something to paper over with a default.
  it "refuses fewer than two cards" do
    expect { described_class.build(1) }.to raise_error(ArgumentError, /single page/)
  end

  it "refuses more cards than it has geometry for" do
    expect { described_class.build(described_class::MAX_CARDS + 1) }
      .to raise_error(ArgumentError, /no geometry/)
  end

  # The constant that broke last time it moved: the old CSS ladder covered
  # exactly three cards, so raising HERO_TILES silently pushed cards four and
  # five off the slide.
  it "covers everything the hero is willing to render" do
    expect(described_class::MAX_CARDS).to be >= Boards::Printables::RenderListingImages::HERO_TILES
  end
end
