require "rails_helper"

# The fallback is written to the TILE, never to the shared Image: `images` are
# library rows — one "i feel tired" sits on boards across unrelated accounts —
# so giving that row "tired"'s art would hand it to all of them and stop art
# generation ever running for the phrase.
RSpec.describe Board, "#find_or_create_images_from_word_list phrase art fallback" do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user) }

  before do
    allow(GenerateImagesJob).to receive(:perform_async)
  end

  it "gives a phrase tile the head word's picture instead of a text placeholder" do
    allow(Boards::PhraseArtFallback).to receive(:art_for)
      .with("I feel tired", user: user).and_return("https://cdn/tired.png")

    board.find_or_create_images_from_word_list(["I feel tired"])

    tile = board.board_images.joins(:image).find_by(images: { label: "i feel tired" })
    expect(tile.display_image_url).to eq("https://cdn/tired.png")
  end

  it "leaves the shared library row alone — the picture belongs to this board" do
    allow(Boards::PhraseArtFallback).to receive(:art_for).and_return("https://cdn/tired.png")

    board.find_or_create_images_from_word_list(["I feel tired"])

    expect(Image.by_label("i feel tired").first.src_url).to be_blank
  end

  # A tile that already resolved to art has a URL, so the fallback cannot
  # displace real library art.
  it "does not touch a tile that already has a picture" do
    image = create(:image, label: "juice", is_private: false, src_url: "https://cdn/juice.png")
    expect(Boards::PhraseArtFallback).not_to receive(:art_for)

    board.find_or_create_images_from_word_list(["juice"])

    tile = board.board_images.find_by(image_id: image.id)
    expect(tile.display_image_url).to eq("https://cdn/juice.png")
  end

  # `""` is the "this tile has no picture" marker and is truthy in Ruby, so a
  # blank? test here would put a symbol back on a tile someone deliberately
  # blanked.
  it "does not overwrite a deliberately blanked picture" do
    allow(Boards::PhraseArtFallback).to receive(:art_for).and_return("https://cdn/tired.png")
    allow_any_instance_of(BoardImage).to receive(:set_defaults) do |bi|
      bi.display_image_url = ""
    end

    board.find_or_create_images_from_word_list(["I feel tired"])

    tile = board.board_images.joins(:image).find_by(images: { label: "i feel tired" })
    expect(tile.display_image_url).to eq("")
  end

  it "logs a phrase miss so the coverage gap is measurable" do
    allow(Boards::PhraseArtFallback).to receive(:art_for).and_return(nil)
    expect(Rails.logger).to receive(:info).with(/PhraseArtFallback miss .*I feel tired/)

    board.find_or_create_images_from_word_list(["I feel tired"])
  end
end
