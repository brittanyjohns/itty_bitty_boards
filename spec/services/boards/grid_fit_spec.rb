require "rails_helper"

RSpec.describe Boards::GridFit do
  describe ".columns_for" do
    it "returns the root for a perfect square so the grid is exactly square" do
      { 4 => 2, 9 => 3, 16 => 4, 25 => 5, 36 => 6, 49 => 7, 64 => 8 }.each do |tiles, columns|
        expect(described_class.columns_for(tiles)).to eq(columns),
          "expected #{tiles} tiles to lay out #{columns}x#{columns}, got #{described_class.columns_for(tiles)}"
      end
    end

    it "prefers a near-square grid with a gap over an exact but strip-shaped fit" do
      # 10 tiles fit exactly at 5x2, but 4x3 with two gaps is the squarer grid.
      expect(described_class.columns_for(10)).to eq(4)
      # 24 fits exactly at 6x4; 5x5 with one gap is squarer.
      expect(described_class.columns_for(24)).to eq(5)
    end

    it "breaks a tie toward the wider grid" do
      expect(described_class.columns_for(6)).to eq(3)  # 3x2, not 2x3
      expect(described_class.columns_for(12)).to eq(4) # 4x3, not 3x4
      expect(described_class.columns_for(30)).to eq(6) # 6x5, not 5x6
    end

    it "caps the width so a long menu gets taller instead of denser" do
      expect(described_class.columns_for(81)).to eq(described_class::MAX_COLUMNS)
      expect(described_class.columns_for(100)).to eq(described_class::MAX_COLUMNS)
    end

    it "never drops below the minimum width" do
      expect(described_class.columns_for(1)).to eq(described_class::MIN_COLUMNS)
      expect(described_class.columns_for(0)).to eq(described_class::MIN_COLUMNS)
      expect(described_class.columns_for(nil)).to eq(described_class::MIN_COLUMNS)
    end

    it "honors caller-supplied bounds" do
      expect(described_class.columns_for(100, max_columns: 12)).to eq(10)
      expect(described_class.columns_for(9, max_columns: 2)).to eq(2)
    end

    it "never leaves more empty cells than a full row" do
      (1..100).each do |tiles|
        columns = described_class.columns_for(tiles)
        rows = (tiles / columns.to_f).ceil
        expect((columns * rows) - tiles).to be < columns
      end
    end
  end
end
