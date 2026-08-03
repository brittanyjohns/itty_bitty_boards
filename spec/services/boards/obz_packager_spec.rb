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

  # Every blob whose bytes could back this doc's zip entry: the original AND
  # the display-size variant the packager actually downloads
  # (ObfExporter#package_source_for). A test simulating an unreadable asset
  # must break the rendition that is really read, or it silently stops
  # simulating anything — which is exactly what happened when :package moved
  # off originals.
  def asset_blob_ids(doc)
    ids = [doc.image.blob.id]
    variant = doc.tile_variant
    processed = variant&.processed
    ids << processed.image.blob.id if processed.respond_to?(:image)
    ids
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

  # The packager downloads bytes for an asset whose path/content_type were
  # decided upstream in ObfExporter. If it re-decides which rendition to read,
  # the zip ends up promising webp and carrying PNG — so assert the entry the
  # manifest names actually holds the smaller variant bytes.
  it "writes the display-size variant bytes under the path the manifest names" do
    board = board_with_tile("Root")
    doc = board.board_images.first.export_doc(user)
    original_size = doc.image.download.bytesize
    scope = Boards::ExportScope::Result.new([board], board, [])

    result = described_class.new(scope, exporting_user: user).call
    files = entries_in(result.bytes)

    manifest = JSON.parse(files["manifest.json"])
    path = manifest["paths"]["images"][doc.id.to_s]

    expect(path).to end_with(".webp")
    expect(files).to have_key(path)
    expect(files[path].bytesize).to be < original_size
    # RIFF....WEBP — the bytes are genuinely webp, not the original renamed.
    expect(files[path][0, 4]).to eq("RIFF")

    obf = JSON.parse(files["boards/#{board.id}.obf"])
    expect(obf["images"].first["path"]).to eq(path)
    expect(obf["images"].first["content_type"]).to eq("image/webp")
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

    broken_blob_ids = asset_blob_ids(shared_doc)
    read_attempts = 0
    allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_wrap_original do |original, *args, &block|
      if broken_blob_ids.include?(original.receiver.id)
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
    broken_blob_ids = asset_blob_ids(broken_doc)

    allow_any_instance_of(ActiveStorage::Blob).to receive(:download).and_wrap_original do |original, *args, &block|
      raise StandardError, "S3 unavailable" if broken_blob_ids.include?(original.receiver.id)

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
    expect(image_entries).to eq(["images/#{doc.id}.webp"])
  end

  # Attaches audio_files (has_many_attached, on Image) BEFORE doc.image
  # (has_one_attached, on Doc) rather than reusing board_with_tile as-is plus
  # a separate audio attach — see the comment on add_tile_with_audio in
  # obf_exporter_spec.rb for why the order matters (an ActiveStorage/Rails-8
  # test-transaction quirk, not a bug in the feature under test).
  it "bundles a board's audio into the sounds/ path and wires the manifest" do
    board = create(:board, user: user, name: "Audio Board")
    image = create(:image, label: "tile", user: user)
    image.audio_files.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
      filename: "line.mp3", content_type: "audio/mpeg",
    )
    doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)
    doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                      filename: "tile.png", content_type: "image/png")
    board.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)
    board.reload

    scope = Boards::ExportScope::Result.new([board], board, [])
    result = described_class.new(scope, exporting_user: user).call
    files = entries_in(result.bytes)

    sound_entries = files.keys.select { |k| k.start_with?("sounds/") }
    expect(sound_entries.size).to eq(1)

    manifest = JSON.parse(files["manifest.json"])
    expect(manifest["paths"]["sounds"]).not_to be_empty
  end

  # sound_entry's zip path used to key on tile.id while the Asset id keyed on
  # attachment.id — a mismatch vs. the image pattern, where both key on
  # doc.id. Two tiles that resolve to the SAME underlying audio attachment
  # (both fall back to the same shared Image's audio, since neither tile has
  # its own custom recording) got two DIFFERENT zip paths for identical
  # bytes, defeating write_assets' path-based dedup — the same bytes were
  # written to the zip twice — and manifest["paths"]["sounds"] (keyed
  # {attachment_id => path}) silently dropped one of the two paths for that
  # id. Mirrors "writes a shared asset's bytes only once..." above, for audio.
  it "writes a shared audio attachment's bytes only once when two tiles' boards reference the same underlying attachment" do
    image = create(:image, label: "shared audio", user: user)
    image.audio_files.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
      filename: "line.mp3", content_type: "audio/mpeg",
    )
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
    result = described_class.new(scope, exporting_user: user).call
    files = entries_in(result.bytes)

    sound_entries = files.keys.select { |k| k.start_with?("sounds/") }
    expect(sound_entries.size).to eq(1)

    manifest = JSON.parse(files["manifest.json"])
    expect(manifest["paths"]["sounds"].size).to eq(1)
  end
end
