require "rails_helper"

RSpec.describe Boards::Printables::BrandAssets do
  let(:owner) { create(:user) }

  describe ".scene_data_uri_for" do
    # The listing is live on Etsy by the time anyone re-renders it. A random or
    # time-based pick would silently re-skin a published listing every time a
    # printable is regenerated, so the choice has to be a pure function of the
    # board.
    it "picks the same scene for the same board every time" do
      board = create(:board, user: owner, name: "Core Words")

      picks = 5.times.map { described_class.scene_index_for(board) }

      expect(picks.uniq.size).to eq(1)
    end

    it "spreads different boards across the scene pool" do
      boards = 40.times.map { |i| create(:board, user: owner, name: "Board #{i}") }

      indexes = boards.map { |b| described_class.scene_index_for(b) }

      expect(indexes.uniq.size).to be > 1
      expect(indexes).to all(be_between(0, described_class::SCENES.size - 1))
    end

    it "returns an inline data URI, never a path or a URL" do
      board = create(:board, user: owner)

      expect(described_class.scene_data_uri_for(board)).to start_with("data:image/jpeg;base64,")
    end
  end

  it "inlines the founder photo and the logo" do
    expect(described_class.founder_photo_data_uri).to start_with("data:image/jpeg;base64,")
    expect(described_class.logo_data_uri).to start_with("data:image/png;base64,")
  end

  # A missing asset must degrade the slide, not take down the whole gallery
  # render — a plainer listing image beats no listing image.
  it "returns nil for an asset that isn't on disk rather than raising" do
    allow(File).to receive(:exist?).and_return(false)
    described_class.instance_variable_set(:@scene_data_uris, nil)

    expect(described_class.scene_data_uri("reading-nook")).to be_nil
  ensure
    described_class.instance_variable_set(:@scene_data_uris, nil)
  end
end
