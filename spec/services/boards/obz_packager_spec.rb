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

  it "bails out mid-write once the running total crosses the cap, without finishing the zip" do
    stub_const("Boards::ObzPackager::MAX_BYTES", 10)
    board = board_with_tile("Root")
    scope = Boards::ExportScope::Result.new([board], board, [])

    read_count_after_raise = nil
    allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_wrap_original do |original, *args, &block|
      result = original.call(*args, &block)
      read_count_after_raise ||= 0
      read_count_after_raise += 1
      result
    end

    expect {
      described_class.new(scope, exporting_user: user).call
    }.to raise_error(Boards::ObzPackager::TooLarge, /limit/)

    # One board, one asset — the incremental check must fire on the first
    # (only) asset read, not after the whole zip (obf entries + manifest +
    # readme) was already built.
    expect(read_count_after_raise).to eq(1)
  end

  # write_assets previously deduped by asset.path only in the "seen" map that
  # gates zip writes — a FAILING asset was never added to "seen", so the same
  # broken doc backing tiles on two boards triggered two S3 reads and two
  # packaging_failures entries for what is, to the user, one broken image.
  it "reads a shared failing asset only once and records one failure, not one per board" do
    board_a = board_with_tile("A")
    board_b = board_with_tile("B")
    shared_doc = board_a.board_images.first.export_doc(user)

    # Re-point board_b's tile at the same doc/image as board_a so both boards
    # reference the identical asset path.
    board_b.board_images.first.update!(image_id: board_a.board_images.first.image_id)

    broken_blob_id = shared_doc.image.blob.id
    read_attempts = 0
    allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_wrap_original do |original, *args, &block|
      if original.receiver.id == broken_blob_id
        read_attempts += 1
        raise StandardError, "S3 unavailable"
      end
      original.call(*args, &block)
    end

    scope = Boards::ExportScope::Result.new([board_a, board_b], board_a, [])
    result = described_class.new(scope, exporting_user: user).call

    expect(read_attempts).to eq(1)
    expect(result.summary["packaging_failures"].size).to eq(1)
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

  it "surfaces attribution-required assets in the summary and README" do
    OpenSymbol.create!(search_string: "sun", license: "CC BY 4.0")
    image = create(:image, label: "sun", user: user)
    create(:doc, documentable: image, user: user, source_type: "OpenSymbol", raw: "sun", current: true)
    board = create(:board, user: user, name: "Attributed")
    board.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)
    board.reload

    scope = Boards::ExportScope::Result.new([board], board, [])
    result = described_class.new(scope, exporting_user: user).call
    files = entries_in(result.bytes)

    expect(result.summary["attribution"].size).to eq(1)
    expect(result.summary["attribution"].first[:label]).to eq("sun")
    expect(files["README.txt"]).to include("attribution")
    expect(files["README.txt"]).to include("sun")
  end

  # doc.image.attached? (checked by ObfExporter#attach_asset) is a DB-level
  # check — it can be true while the underlying S3 object is missing,
  # corrupted, or transiently unreachable. The actual byte read happens later,
  # inside ObzPackager itself, and must not be allowed to crash the whole
  # package over one bad blob.
  it "does not crash the whole package when one asset's blob is unreadable, and records the failure" do
    broken_board = board_with_tile("Broken")
    healthy_board = board_with_tile("Healthy")
    broken_doc = broken_board.board_images.first.export_doc(user)
    broken_doc_id = broken_doc.id
    broken_blob_id = broken_doc.image.blob.id

    allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_wrap_original do |original, *args, &block|
      raise StandardError, "S3 unavailable" if original.receiver.id == broken_blob_id

      original.call(*args, &block)
    end

    scope = Boards::ExportScope::Result.new([broken_board, healthy_board], broken_board, [])

    result = nil
    expect {
      result = described_class.new(scope, exporting_user: user).call
    }.not_to raise_error

    files = entries_in(result.bytes)
    expect(files.keys).to include("boards/#{broken_board.id}.obf", "boards/#{healthy_board.id}.obf")

    failures = result.summary["packaging_failures"]
    expect(failures.size).to eq(1)
    expect(failures.first[:doc_id]).to eq(broken_doc_id)

    expect(files).to have_key("README.txt")
    expect(files["README.txt"]).to include("could not be included")
  end

  # write_assets dedupes by asset.path, which is derived from doc.id — so the
  # same Doc backing tiles on two different boards must only be written to
  # the zip once. Independently traced as correct by two prior reviewers but
  # had zero test coverage.
  it "writes a shared asset's bytes only once when two boards' tiles reference the same doc" do
    image = create(:image, label: "shared tile", user: user)
    doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)
    doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                      filename: "tile.png", content_type: "image/png")

    board_a = create(:board, user: user, name: "A")
    board_a.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)
    board_a.reload

    board_b = create(:board, user: user, name: "B")
    board_b.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)
    board_b.reload

    scope = Boards::ExportScope::Result.new([board_a, board_b], board_a, [])
    files = entries_in(described_class.new(scope, exporting_user: user).call.bytes)

    image_entries = files.keys.select { |k| k.start_with?("images/") }
    expect(image_entries).to eq(["images/#{doc.id}.png"])
  end
end
