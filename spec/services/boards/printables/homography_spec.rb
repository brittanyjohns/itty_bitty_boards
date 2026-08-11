require "rails_helper"

RSpec.describe Boards::Printables::Homography do
  # Clockwise from top-left, the shape of a tablet screen seen at an angle.
  let(:quad) { [[368, 242], [1152, 242], [1156, 766], [360, 764]] }

  describe ".solve" do
    # The whole contract: the four corners of the source rectangle land exactly
    # on the four corners of the quad. Everything else follows from that, and
    # nothing about a rendered PNG would show you if it didn't.
    it "maps each corner of the source rectangle onto its corner of the quad" do
      solution = described_class.solve(800, 600, quad)

      corners = [[0, 0], [800, 0], [800, 600], [0, 600]]
      landed = corners.map { |x, y| described_class.apply(solution, x, y) }

      landed.zip(quad).each do |(got_x, got_y), (want_x, want_y)|
        expect(got_x).to be_within(1e-6).of(want_x)
        expect(got_y).to be_within(1e-6).of(want_y)
      end
    end

    it "keeps the centre of the rectangle inside the quad" do
      solution = described_class.solve(800, 600, quad)

      x, y = described_class.apply(solution, 400, 300)

      expect(x).to be_between(368, 1156)
      expect(y).to be_between(242, 766)
    end

    it "refuses a quad whose corners are collinear rather than returning noise" do
      collinear = [[0, 0], [100, 0], [200, 0], [300, 0]]

      expect { described_class.solve(800, 600, collinear) }
        .to raise_error(described_class::DegenerateQuadError)
    end

    it "refuses a source rectangle with no area" do
      expect { described_class.solve(0, 600, quad) }.to raise_error(ArgumentError)
    end
  end

  describe ".matrix3d" do
    it "emits the sixteen column-major cells CSS expects" do
      css = described_class.matrix3d(800, 600, quad)

      expect(css).to start_with("matrix3d(")
      expect(css[/\((.*)\)/, 1].split(",").size).to eq(16)
    end

    # A rectangle mapped onto itself is the identity, and the z row/column are
    # left alone — the cheapest check that the 3x3 is embedded the right way up.
    it "is the identity when the quad is the source rectangle" do
      css = described_class.matrix3d(100, 50, [[0, 0], [100, 0], [100, 50], [0, 50]])

      cells = css[/\((.*)\)/, 1].split(",").map { |n| n.strip.to_f }
      expect(cells).to eq([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])
    end
  end
end
