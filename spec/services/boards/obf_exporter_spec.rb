require "rails_helper"

RSpec.describe Boards::ObfExporter do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, name: "Snack Time", large_screen_columns: 2) }

  # The doc MUST have an attached blob: ObfExporter only bundles bytes it can
  # actually read, so a doc with no attachment degrades to a url reference and
  # contributes no asset.
  def add_tile(label, doc_source_type: Doc::SOURCE_TYPE_USER, doc_user: user)
    image = create(:image, label: label, user: user)
    doc = create(:doc, documentable: image, user: doc_user, source_type: doc_source_type, current: true)
    doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                     filename: "tile.png", content_type: "image/png")
    board.board_images.create!(image_id: image.id, position: board.board_images.count,
                               skip_create_voice_audio: true)
  end

  before do
    allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/i.png")
    allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
  end

  it "produces a spec-shaped OBF document" do
    add_tile("apple")
    result = described_class.new(board.reload, exporting_user: user).call

    expect(result.obf["format"]).to eq("open-board-0.1")
    expect(result.obf["name"]).to eq("Snack Time")
    expect(result.obf["id"]).to eq(board.id.to_s)
    expect(result.obf["buttons"].size).to eq(1)
  end

  it "matches every grid order id to a button id" do
    add_tile("apple")
    add_tile("banana")
    board.reload.set_layouts_for_screen_sizes

    result = described_class.new(board.reload, exporting_user: user).call
    button_ids = result.obf["buttons"].map { |b| b[:id] }

    expect(result.obf["grid"]["order"].flatten.compact).to match_array(button_ids)
  end

  describe "the two licensing decisions are independent" do
    it "bundles every asset of a user's own board AND declares it private" do
      add_tile("grandma")
      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.skipped_assets).to be_empty
      expect(result.assets.size).to eq(1)
      expect(result.obf["license"]["type"]).to eq("private")
    end

    # Doc#extension reads original_image_url, which is nil for user uploads.
    # The zip path must come from the blob or it ends in a bare dot.
    it "derives the asset extension from the attached blob" do
      add_tile("grandma")
      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.assets.first.path).to match(%r{\Aimages/\d+\.png\z})
    end

    it "skips a proprietary asset but still exports the board" do
      OpenSymbol.create!(search_string: "cup", license: "CC BY", protected_symbol: "true")
      image = create(:image, label: "cup", user: user)
      create(:doc, documentable: image, user: user, source_type: "OpenSymbol", raw: "cup", current: true)
      board.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.assets).to be_empty
      expect(result.skipped_assets.first[:reason]).to match(/proprietary/i)
      expect(result.obf["buttons"].size).to eq(1)
      expect(result.obf["images"].first[:url]).to be_present
    end
  end

  it "wires load_board paths for linked boards" do
    target = create(:board, user: user, name: "Drinks")
    tile = add_tile("more")
    tile.update!(predictive_board_id: target.id)

    result = described_class.new(
      board.reload, exporting_user: user, asset_mode: :package,
      board_paths: { target.id => "boards/#{target.id}.obf" }
    ).call

    expect(result.obf["buttons"].first[:load_board][:path]).to eq("boards/#{target.id}.obf")
  end
end
