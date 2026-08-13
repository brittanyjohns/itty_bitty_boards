# spec/requests/api/board_images_hide_pictures_spec.rb
#
# Covers the bulk "Hide pictures" toggle on
# PUT /api/board_images/update (BoardImagesController#update_multiple).
# The frontend bulk-edit drawer sends payload[:hide_pictures].
#
# The mechanism is a BLANK display_image_url, which is already the app-wide
# marker for "this tile has no picture" — every resolver chains with a bare
# `||` and "" is truthy in Ruby, so the chain stops there instead of falling
# through to the shared Image's art. Reusing that marker (rather than adding a
# second flag) is what makes the toggle work in PDF exports, board covers, and
# printables without teaching each renderer about it — see
# Boards::BoardPdfLayoutNormalizer and its spec.
#
# This is NOT board_image.hidden ("Hide tiles"), which drops the tile from the
# board entirely. Hide pictures keeps the tile — and its label, colors, and
# audio — and it still speaks.

require "rails_helper"

RSpec.describe "BoardImages bulk hide_pictures", type: :request do
  def j
    JSON.parse(response.body) rescue {}
  end

  before do
    allow_any_instance_of(API::ApplicationController)
      .to receive(:authenticate_token!).and_return(true)
    allow_any_instance_of(API::ApplicationController)
      .to receive(:current_user).and_return(user)
  end

  let!(:user)  { create(:user) }
  let!(:board) { create(:board, user: user) }
  let!(:image) { create(:image, user: user, label: "cookie") }
  let!(:board_image) do
    create(:board_image, board: board, image: image).tap do |bi|
      bi.update!(display_image_url: "https://example.com/cookie.png")
    end
  end

  # as: :json on purpose — the bulk drawer posts a JSON body, so `false`
  # arrives as a real boolean. Form-encoding would deliver the string "false",
  # which is truthy in Ruby; see the "string 'false'" example below for why
  # hide_pictures survives that and its older neighbours would not.
  def put_payload(payload)
    put "/api/board_images/update",
        params: {
          board_id: board.id,
          board_image_ids: [board_image.id],
          payload: payload,
        },
        as: :json
  end

  it "blanks the picture when hide_pictures is true" do
    put_payload(hide_pictures: true)
    expect(response.status).to eq(200)
    expect(board_image.reload.display_image_url).to eq("")
  end

  # The whole point of "" over nil: nil falls through the `||` chain to the
  # shared Image's art, so the tile would still show a picture.
  it "blanks to an empty string, never nil" do
    put_payload(hide_pictures: true)
    expect(board_image.reload.display_image_url).not_to be_nil
    expect(board_image.picture_hidden?).to be(true)
  end

  # nil is the exact inverse of "": it lets the `||` chain fall back through to
  # the shared Image's art, so the tile shows a picture again.
  it "puts the picture back when hide_pictures is false" do
    board_image.update!(display_image_url: "")
    put_payload(hide_pictures: false)
    expect(response.status).to eq(200)
    board_image.reload
    expect(board_image.display_image_url).to be_nil
    expect(board_image.picture_hidden?).to be(false)
  end

  # Un-hiding must never clobber a tile that already has art — including a
  # custom per-tile picture the parent chose.
  it "leaves an existing picture alone when hide_pictures is false" do
    put_payload(hide_pictures: false)
    expect(response.status).to eq(200)
    expect(board_image.reload.display_image_url)
      .to eq("https://example.com/cookie.png")
  end

  # The guard that makes this endpoint safe for callers that don't know about
  # the toggle — a layout-only or color-only save must not turn pictures back on.
  it "leaves the picture alone when hide_pictures is omitted" do
    board_image.update!(display_image_url: "")
    put_payload(bg_color: "#FF0000")
    expect(response.status).to eq(200)
    expect(board_image.reload.display_image_url).to eq("")
  end

  # The cast means a form-encoded client gets the same answer as a JSON one.
  it "treats the string \"false\" as false" do
    board_image.update!(display_image_url: "")
    put "/api/board_images/update",
        params: {
          board_id: board.id,
          board_image_ids: [board_image.id],
          payload: { hide_pictures: "false" },
        }
    expect(response.status).to eq(200)
    expect(board_image.reload.picture_hidden?).to be(false)
  end

  it "is independent of hidden — hiding pictures does not hide the tile" do
    put_payload(hide_pictures: true)
    expect(board_image.reload.hidden).to be(false)
    expect(board_image.picture_hidden?).to be(true)
  end

  it "is independent of hide_labels" do
    put_payload(hide_pictures: true, hide_labels: false)
    board_image.reload
    expect(board_image.picture_hidden?).to be(true)
    expect(board_image.hide_label).to be(false)
  end

  it "serializes the blank picture on the board api view the editor reads" do
    put_payload(hide_pictures: true)
    tile = j.dig("board", "images")
            &.find { |i| i["board_image_id"] == board_image.id.to_s }
    expect(tile).to be_present
    expect(tile["src"]).to eq("")
  end

  describe "the Speak view" do
    it "serializes the blank picture on the native grid api view" do
      board_image.update!(display_image_url: "")
      tile = board.reload
                  .api_view_for_native_grid(user)[:images]
                  .find { |i| i[:board_image_id] == board_image.id.to_s }
      expect(tile[:src]).to eq("")
    end
  end

  describe "BoardImage#picture_hidden?" do
    it "is false for a tile with a picture" do
      expect(board_image.picture_hidden?).to be(false)
    end

    it "is false when the url was never set, since that falls through to the image" do
      board_image.update_column(:display_image_url, nil)
      expect(board_image.reload.picture_hidden?).to be(false)
    end

    it "is true only for a blank string" do
      board_image.update!(display_image_url: "")
      expect(board_image.reload.picture_hidden?).to be(true)
    end
  end
end
