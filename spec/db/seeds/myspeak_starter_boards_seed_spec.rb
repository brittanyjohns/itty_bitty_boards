require "rails_helper"

RSpec.describe "db/seeds/myspeak_starter_boards.rb", type: :model do
  let(:seed_path) { Rails.root.join("db/seeds/myspeak_starter_boards.rb") }

  def run_seed
    load seed_path.to_s
  end

  before do
    FactoryBot.create(:user, id: User::DEFAULT_ADMIN_ID)
    allow(AacWordCategorizer).to receive(:categorize).and_return("noun")
    allow(SaveAudioJob).to receive(:perform_async)
    allow(GenerateImagesJob).to receive(:perform_async)
  end

  it "creates 5 myspeak-tagged public boards each with >= 6 tiles" do
    run_seed

    boards = Board.myspeak_public_boards
    expect(boards.count).to eq(5)

    expected_slugs = %w[myspeak-basics myspeak-feelings myspeak-social myspeak-food myspeak-school]
    expect(boards.pluck(:slug)).to match_array(expected_slugs)

    boards.each do |b|
      expect(b.tags).to include("myspeak")
      expect(b.predefined).to be(true)
      expect(b.published).to be(true)
      expect(b.user_id).to eq(User::DEFAULT_ADMIN_ID)
      expect(b.board_images.count).to be >= 6
    end
  end

  it "is idempotent — re-running does not duplicate boards or tiles" do
    run_seed
    counts_before = Board.myspeak_public_boards.map { |b| [b.slug, b.board_images.count] }.to_h

    run_seed
    counts_after = Board.myspeak_public_boards.map { |b| [b.slug, b.board_images.count] }.to_h

    expect(Board.myspeak_public_boards.count).to eq(5)
    expect(counts_after).to eq(counts_before)
  end

  it "tags each board so it appears in GET /api/public_boards?myspeak=true scope" do
    run_seed
    expect(Board.myspeak_public_boards.pluck(:slug)).to include(
      "myspeak-basics", "myspeak-feelings", "myspeak-social",
      "myspeak-food", "myspeak-school"
    )
  end
end
