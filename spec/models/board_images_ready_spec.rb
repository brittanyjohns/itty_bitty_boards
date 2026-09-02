# frozen_string_literal: true

require "rails_helper"

# #824 finding 3: "board ready" and "board renderable" are different facts.
# GenerateBoardJob flips a board to `complete` immediately after enqueuing
# per-tile art, so a client told "ready" can open a board whose tiles are all
# still text.
RSpec.describe "Board#images_ready?" do
  let(:board) { create(:board, user: create(:user)) }

  def tile(status: "pending", display_image_url: nil, src_url: "https://cdn/apple.png", label: "apple", hidden: false)
    image = create(:image, label: label, src_url: src_url)
    board_image = create(:board_image, board: board, image: image, label: label, hidden: hidden)
    board_image.update_columns(status: status, display_image_url: display_image_url)
    board_image.reload
  end

  it "is ready when every visible tile resolves to library art" do
    2.times { |i| tile(label: "word-#{i}") }

    expect(board.reload.tiles_awaiting_art_count).to eq(0)
    expect(board.images_ready?).to be(true)
  end

  it "is not ready while a tile's art is being generated" do
    tile
    tile(status: "generating", label: "pear")

    expect(board.reload.tiles_awaiting_art_count).to eq(1)
    expect(board.images_ready?).to be(false)
  end

  it "is not ready when a tile has no art anywhere yet — the text-only tile" do
    tile(src_url: nil, label: "pear")

    expect(board.reload.images_ready?).to be(false)
  end

  it "treats `pending` as ready, because it is the column default" do
    # Every ordinary tile that never went through art generation sits here.
    # Reading it as 'queued' would report almost every board as never ready.
    tile(status: "pending")

    expect(board.reload.images_ready?).to be(true)
  end

  it "treats a BLANK picture as ready — that is 'this tile has no picture'" do
    # The Hide-pictures marker. It is a deliberate, renderable state: the
    # client draws the label on the tile's colour.
    blank = tile(label: "red")
    blank.update_columns(display_image_url: "")

    expect(blank.reload).to be_picture_hidden
    expect(board.reload.images_ready?).to be(true)
  end

  it "ignores hidden tiles — a viewer never waits on a tile they can't see" do
    tile
    tile(status: "generating", hidden: true, label: "pear")

    expect(board.reload.images_ready?).to be(true)
  end

  it "counts a tile the narrower has_generating_images? misses" do
    tile(src_url: nil, label: "pear")

    expect(board.reload.has_generating_images?).to be(false)
    expect(board.images_ready?).to be(false)
  end

  it "rides on the board payloads a client polls" do
    tile(status: "generating")

    view = board.reload.api_view_with_images(board.user)
    expect(view[:images_ready]).to be(false)
    expect(view[:tiles_awaiting_art]).to eq(1)

    expect(board.api_view_for_native_grid(board.user)[:images_ready]).to be(false)
    expect(board.api_view_with_predictive_images(board.user)[:images_ready]).to be(false)
  end

  it "stays off api_view, which serializes board lists" do
    tile

    expect(board.reload.api_view(board.user)).not_to have_key(:images_ready)
  end
end
