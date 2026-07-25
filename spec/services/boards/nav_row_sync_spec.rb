require "rails_helper"

RSpec.describe Boards::NavRowSync do
  let(:user) { create(:user) }
  let!(:root) { create(:board, user: user, name: "Core 60", large_screen_columns: 6) }
  let!(:food) { create(:board, user: user, name: "Food", large_screen_columns: 6) }
  let!(:drinks) { create(:board, user: user, name: "Drinks", large_screen_columns: 6) }

  def tile(board, label, x:, y:, position:, target: nil, data: {})
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, predictive_board_id: target, data: data)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  # Root: a content row, then a nav row of `this | Food | Drinks | that`.
  before do
    %w[I want go stop].each_with_index { |l, x| tile(root, l, x: x, y: 0, position: x + 1) }
    tile(root, "this", x: 0, y: 1, position: 10)
    tile(root, "Food", x: 1, y: 1, position: 11, target: food.id)
    tile(root, "Drinks", x: 2, y: 1, position: 12, target: drinks.id)
    tile(root, "that", x: 3, y: 1, position: 13)
  end

  def nav_cells(board)
    board.board_images.reload.select { |bi| bi.data&.dig("nav_tile") }.map do |bi|
      { label: bi.label, x: bi.layout["lg"]["x"], y: bi.layout["lg"]["y"],
        target: bi.predictive_board_id, muted: bi.data["mute_name"] }
    end.sort_by { |c| [c[:y], c[:x]] }
  end

  it "projects the root's nav row onto every child at the same cells" do
    described_class.call(root)

    expect(nav_cells(food).map { |c| [c[:label], c[:x], c[:y]] }).to eq(
      [["this", 0, 1], ["Food", 1, 1], ["Drinks", 2, 1], ["that", 3, 1]]
    )
  end

  it "points the self-tile at the root and leaves it unmuted" do
    described_class.call(root)

    self_tile = nav_cells(food).find { |c| c[:label] == "Food" }
    other     = nav_cells(food).find { |c| c[:label] == "Drinks" }

    expect(self_tile[:target]).to eq(root.id)
    expect(self_tile[:muted]).to be_falsey
    expect(other[:target]).to eq(drinks.id)
    expect(other[:muted]).to be(true)
  end

  it "is idempotent" do
    described_class.call(root)
    first = nav_cells(food)

    expect { described_class.call(root) }.not_to change { food.board_images.reload.count }
    expect(nav_cells(food)).to eq(first)
  end

  it "deletes a stale nav folder tile that is no longer in the region" do
    stale_page = create(:board, user: user, name: "Home")
    tile(food, "Home", x: 0, y: 1, position: 1, target: stale_page.id)

    result = described_class.call(root)

    expect(food.board_images.reload.map(&:label)).not_to include("Home")
    expect(result.folders_deleted).to eq(1)
  end

  it "relocates a user's word tile out of a nav cell instead of deleting it" do
    tile(food, "pizza", x: 1, y: 1, position: 1)

    result = described_class.call(root)

    pizza = food.board_images.reload.find { |bi| bi.label == "pizza" }
    expect(pizza).to be_present                       # never dropped
    expect(pizza.layout["lg"]["y"]).to be < 1         # moved into the content area
    expect(result.words_relocated).to eq(1)
  end

  it "reaches depth-2 boards" do
    greetings = create(:board, user: user, name: "Greetings", large_screen_columns: 6)
    phrases   = create(:board, user: user, name: "Phrases", large_screen_columns: 6)
    tile(root, "Phrases", x: 4, y: 1, position: 14, target: phrases.id)
    tile(phrases, "Greetings", x: 0, y: 0, position: 1, target: greetings.id)

    described_class.call(root)

    expect(nav_cells(greetings).map { |c| c[:label] }).to include("Food", "Drinks", "Phrases")
  end

  it "writes nothing on a dry run but still reports the work" do
    result = described_class.call(root, dry_run: true)

    expect(food.board_images.reload).to be_empty
    expect(result.boards_synced).to eq(2)         # Food + Drinks
    expect(result.tiles_written).to eq(8)         # 4 nav cells x 2 pages
  end
end
