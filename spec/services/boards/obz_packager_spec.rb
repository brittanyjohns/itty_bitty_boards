require "rails_helper"
require "zip"

RSpec.describe Boards::ObzPackager do
  let(:user) { create(:user) }

  def entries_in(bytes)
    names = {}
    Zip::File.open_buffer(bytes) { |zip| zip.each { |e| names[e.name] = e.get_input_stream.read } }
    names
  end

  # The doc MUST carry an attached blob: ObfExporter (asset_mode: :package)
  # only bundles bytes it can actually read, so a doc with no attachment
  # degrades to a url reference and is recorded as a skipped asset — which
  # would make every board "dirty" and defeat the README-only-when-something-
  # was-left-out assertion below. Mirrors Boards::ObfExporter's own spec.
  def board_with_tile(name)
    board = create(:board, user: user, name: name)
    image = create(:image, label: "tile", user: user)
    doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)
    doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                      filename: "tile.png", content_type: "image/png")
    board.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)
    board.reload
  end

  before do
    allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/i.png")
    allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
  end

  it "writes a manifest whose root points at a board entry" do
    board = board_with_tile("Root")
    scope = Boards::ExportScope::Result.new([board], board, [])

    result = described_class.new(scope, exporting_user: user).call
    files = entries_in(result.bytes)

    manifest = JSON.parse(files["manifest.json"])
    expect(manifest["format"]).to eq("open-board-0.1")
    expect(manifest["root"]).to eq("boards/#{board.id}.obf")
    expect(files).to have_key(manifest["root"])
    expect(manifest["paths"]["boards"].values).to include("boards/#{board.id}.obf")
  end

  it "writes one obf entry per board" do
    a = board_with_tile("A")
    b = board_with_tile("B")
    scope = Boards::ExportScope::Result.new([a, b], a, [])

    files = entries_in(described_class.new(scope, exporting_user: user).call.bytes)

    expect(files.keys).to include("boards/#{a.id}.obf", "boards/#{b.id}.obf")
  end

  it "refuses to build a package over the size cap" do
    stub_const("Boards::ObzPackager::MAX_BYTES", 10)
    board = board_with_tile("Root")
    scope = Boards::ExportScope::Result.new([board], board, [])

    expect {
      described_class.new(scope, exporting_user: user).call
    }.to raise_error(Boards::ObzPackager::TooLarge, /limit/)
  end

  it "includes a README only when something was left out" do
    board = board_with_tile("Root")

    clean = described_class.new(
      Boards::ExportScope::Result.new([board], board, []), exporting_user: user
    ).call
    expect(entries_in(clean.bytes)).not_to have_key("README.txt")

    with_skips = described_class.new(
      Boards::ExportScope::Result.new([board], board, [{ board_id: 999, reason: "not readable by the exporting user" }]),
      exporting_user: user
    ).call
    files = entries_in(with_skips.bytes)
    expect(files).to have_key("README.txt")
    expect(files["README.txt"]).to include("not readable")
  end
end
