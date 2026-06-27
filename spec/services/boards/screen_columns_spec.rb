require "rails_helper"

RSpec.describe Boards::ScreenColumns do
  describe ".derive" do
    it "returns the large count unchanged for lg" do
      expect(described_class.derive(12, "lg")).to eq(12)
      expect(described_class.derive(6, "lg")).to eq(6)
    end

    # md ≈ 2/3 of lg, sm ≈ 1/3 of lg, rounded and clamped.
    [
      [12, 8, 4],
      [10, 7, 3],
      [8, 5, 3],
      [6, 4, 2],
      [4, 3, 2],
    ].each do |lg, md, sm|
      it "derives md=#{md}, sm=#{sm} from lg=#{lg}" do
        expect(described_class.derive(lg, "md")).to eq(md)
        expect(described_class.derive(lg, "sm")).to eq(sm)
      end
    end

    it "keeps the order sm <= md <= lg for every reasonable lg" do
      (1..24).each do |lg|
        sm = described_class.derive(lg, "sm")
        md = described_class.derive(lg, "md")
        expect(sm).to be <= md
        expect(md).to be <= lg
      end
    end

    it "never drops sm below the 2-column floor once lg is wide enough" do
      (4..24).each do |lg|
        expect(described_class.derive(lg, "sm")).to be >= 2
      end
    end

    it "never exceeds lg even for tiny boards" do
      expect(described_class.derive(1, "sm")).to eq(1)
      expect(described_class.derive(1, "md")).to eq(1)
      expect(described_class.derive(2, "md")).to be <= 2
    end

    it "treats xs/xxs like sm" do
      expect(described_class.derive(12, "xs")).to eq(described_class.derive(12, "sm"))
      expect(described_class.derive(12, "xxs")).to eq(described_class.derive(12, "sm"))
    end

    it "coerces non-positive large counts to a 1-column floor" do
      expect(described_class.derive(0, "lg")).to eq(1)
      expect(described_class.derive(nil, "md")).to eq(1)
    end
  end
end
