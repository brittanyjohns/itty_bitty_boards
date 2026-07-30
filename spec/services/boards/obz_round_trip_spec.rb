require "rails_helper"

# Export -> import, against the real ObzImporter. If the package layout, the
# manifest shape, or the grid/button id types drift, this fails.
RSpec.describe "OBZ export/import round trip" do
  let(:exporter_user) { create(:user) }
  let(:importer_user) { create(:user) }

  before do
    allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/i.png")
    allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
  end

  def tile(board, label, links_to: nil)
    image = create(:image, label: label, user: exporter_user)
    board.board_images.create!(image_id: image.id, position: board.board_images.count,
                               predictive_board_id: links_to&.id, skip_create_voice_audio: true)
  end

  it "preserves boards, labels, grid positions and links" do
    root  = create(:board, user: exporter_user, name: "Home", large_screen_columns: 2)
    child = create(:board, user: exporter_user, name: "Drinks", large_screen_columns: 2)
    tile(child, "water")
    tile(root, "hello")
    tile(root, "drinks", links_to: child)
    root.reload.set_layouts_for_screen_sizes

    scope = Boards::ExportScope.for_board(root.reload, exporting_user: exporter_user)
    expect(scope.boards.map(&:name)).to match_array(["Home", "Drinks"])

    package = Boards::ObzPackager.new(scope, exporting_user: exporter_user).call

    group = BoardGroup.create!(name: "Imported", user_id: importer_user.id)
    result = ObzImporter.new(package.bytes, importer_user, board_group: group, import_all: true).import!

    imported = result[:boards].values
    expect(imported.size).to eq(2)
    expect(imported.map(&:name)).to match_array(["Home", "Drinks"])

    imported_root = result[:root_board]
    expect(imported_root.name).to eq("Home")
    expect(imported_root.board_images.map(&:label)).to match_array(%w[hello drinks])

    # The folder tile must still open a board after the trip.
    folder = imported_root.board_images.find { |bi| bi.label == "drinks" }
    expect(folder.predictive_board_id).to be_present
    expect(Board.find(folder.predictive_board_id).name).to eq("Drinks")
  end

  it "produces a package whose grid order ids all match button ids" do
    board = create(:board, user: exporter_user, name: "Grid", large_screen_columns: 2)
    3.times { |i| tile(board, "t#{i}") }
    board.reload.set_layouts_for_screen_sizes

    scope = Boards::ExportScope.for_board(board.reload, exporting_user: exporter_user)
    package = Boards::ObzPackager.new(scope, exporting_user: exporter_user).call

    obf = nil
    Zip::File.open_buffer(package.bytes) do |zip|
      entry = zip.find { |e| e.name.end_with?(".obf") }
      obf = JSON.parse(entry.get_input_stream.read)
    end

    button_ids = obf["buttons"].map { |b| b["id"] }
    order_ids  = obf["grid"]["order"].flatten.compact

    expect(order_ids).to all(be_a(String))
    expect(order_ids - button_ids).to be_empty
  end
end
