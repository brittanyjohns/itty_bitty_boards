require "rails_helper"

RSpec.describe "BoardsHelper#format_grid" do
  let(:user) { create(:user) }

  def board_with_tiles(count, columns: 3)
    board = create(:board, user: user, large_screen_columns: columns)
    count.times do |i|
      image = create(:image, label: "tile_#{i}", user: user)
      board.board_images.create!(image_id: image.id, position: i, skip_create_voice_audio: true)
    end
    board.reload
  end

  it "emits order cell ids as strings so they match button ids" do
    board = board_with_tiles(3)
    board.set_layouts_for_screen_sizes

    grid = board.format_grid
    ids = grid["order"].flatten.compact

    expect(ids).to all(be_a(String))
    button_ids = board.board_images.map { |bi| bi.to_obf_button_format[:id] }
    expect(ids).to match_array(button_ids)
  end

  it "falls back to position ordering when the layout is blank" do
    board = board_with_tiles(4, columns: 2)
    board.update_column(:layout, {})

    grid = board.format_grid

    expect(grid["columns"]).to eq(2)
    expect(grid["rows"]).to eq(2)
    expect(grid["order"].flatten.compact.size).to eq(4)
  end

  it "uses the derived column count when large_screen_columns is unset" do
    board = board_with_tiles(2)
    board.update_column(:large_screen_columns, 0)

    expect(board.format_grid["columns"]).to be > 0
  end
end
