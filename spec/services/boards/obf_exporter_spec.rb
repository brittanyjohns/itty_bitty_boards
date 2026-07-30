require "rails_helper"

RSpec.describe Boards::ObfExporter do
  let(:user) { create(:user) }
  let(:board) { create(:board, user: user, name: "Snack Time", large_screen_columns: 2) }

  # The doc MUST have an attached blob: ObfExporter only bundles bytes it can
  # actually read, so a doc with no attachment degrades to a url reference and
  # contributes no asset.
  def add_tile(label, doc_source_type: Doc::SOURCE_TYPE_USER, doc_user: user, target_board: board)
    image = create(:image, label: label, user: user)
    doc = create(:doc, documentable: image, user: doc_user, source_type: doc_source_type, current: true)
    doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                     filename: "tile.png", content_type: "image/png")
    target_board.board_images.create!(image_id: image.id, position: target_board.board_images.count,
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

    it "records an attribution entry for a bundled CC BY asset" do
      OpenSymbol.create!(search_string: "sun", license: "CC BY 4.0")
      image = create(:image, label: "sun", user: user)
      create(:doc, documentable: image, user: user, source_type: "OpenSymbol", raw: "sun", current: true)
      board.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.attribution.size).to eq(1)
      expect(result.attribution.first).to include(label: "sun", license_type: a_string_matching(/cc by/i))
    end

    it "does not record attribution for the user's own content" do
      add_tile("grandma")
      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.attribution).to be_empty
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

    # Regression: the empty-license fallback used to fall into the same
    # branch as "everything bundled was open," declaring CC BY-SA 4.0 over
    # content nobody ever evaluated as licensable. Absence of evidence is not
    # evidence of openness — a board where every tile was skipped must stay
    # private.
    it "declares private, not an open license, when every asset was skipped" do
      OpenSymbol.create!(search_string: "cup", license: "CC BY", protected_symbol: "true")
      image = create(:image, label: "cup", user: user)
      create(:doc, documentable: image, user: user, source_type: "OpenSymbol", raw: "cup", current: true)
      board.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.obf["license"]["type"]).to eq("private")
    end

    # Regression: `.sort.last` on license type strings is alphabetical, not by
    # restrictiveness — "public domain" sorts after "cc by-nc-sa 4.0" and used
    # to win, silently dropping the NC-SA obligations the other asset carries.
    it "declares the most restrictive recognized type, not the alphabetically last one" do
      OpenSymbol.create!(search_string: "nc-sa-thing", license: "CC BY-NC-SA 4.0")
      OpenSymbol.create!(search_string: "pd-thing", license: "Public Domain")

      restrictive_image = create(:image, label: "nc-sa-thing", user: user)
      create(:doc, documentable: restrictive_image, user: user, source_type: "OpenSymbol",
                   raw: "nc-sa-thing", current: true)
      board.board_images.create!(image_id: restrictive_image.id, position: 0, skip_create_voice_audio: true)

      open_image = create(:image, label: "pd-thing", user: user)
      create(:doc, documentable: open_image, user: user, source_type: "OpenSymbol",
                   raw: "pd-thing", current: true)
      board.board_images.create!(image_id: open_image.id, position: 1, skip_create_voice_audio: true)

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      type = result.obf["license"]["type"]
      expect(type).to include("nc")
      expect(type).to include("sa")
    end
  end

  it "uses the board's language for locale (regression: was hardcoded 'en')" do
    es_board = create(:board, user: user, name: "Casa", language: "es")
    add_tile("manzana", target_board: es_board)

    result = described_class.new(es_board.reload, exporting_user: user).call

    expect(result.obf["locale"]).to eq("es")
  end

  it "drops sound entries when there's no audio file (regression: emitted id='')" do
    add_tile("apple")

    result = described_class.new(board.reload, exporting_user: user).call

    expect(result.obf["sounds"]).to be_empty
  end

  it "omits load_board on a button whose tile has no predictive_board_id at all" do
    add_tile("apple")

    result = described_class.new(board.reload, exporting_user: user).call

    expect(result.obf["buttons"].first).not_to have_key(:load_board)
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

  describe "sound bundling (asset_mode: :package)" do
    # Deliberately attaches audio_files (has_many_attached, on Image) BEFORE
    # doc.image (has_one_attached, on Doc) rather than reusing add_tile as-is
    # + a separate attach_audio call. Attaching a has_one_attached AFTER
    # another real attach already happened earlier in the same example trips
    # an ActiveStorage/Rails-8 test-transaction quirk unrelated to this
    # feature: the earlier has_one_attached's deferred after_commit upload
    # re-reads its io once the later attach's transaction flushes, and that
    # io is by then exhausted, raising IOError "closed stream". Attaching the
    # has_many_attached first avoids ever triggering it. See task-6-report.md.
    def add_tile_with_audio(label, filename: "line.mp3")
      image = create(:image, label: label, user: user)
      image.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: filename, content_type: "audio/mpeg",
      )
      doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)
      doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                       filename: "tile.png", content_type: "image/png")
      board.board_images.create!(image_id: image.id, position: board.board_images.count,
                                 skip_create_voice_audio: true)
    end

    it "bundles audio bytes and references them by path, not url" do
      add_tile_with_audio("apple")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      sound = result.obf["sounds"].first
      expect(sound[:path]).to match(%r{\Asounds/.+\.mp3\z})
      expect(sound).not_to have_key(:url)
      expect(sound[:content_type]).to eq("audio/mpeg")
    end

    it "adds a :sound asset for the packager to write" do
      add_tile_with_audio("apple")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      sound_assets = result.assets.select { |a| a.kind == :sound }
      expect(sound_assets.size).to eq(1)
    end

    it "falls back to a url reference when there is no audio attachment" do
      tile = add_tile("apple")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.obf["sounds"]).to be_empty
    end

    # A per-tile custom recording (BoardImage#has_custom_audio?, attached via
    # BoardImagesController#upload_audio to the TILE's own audio_files) lives
    # in a different place than the shared Image's TTS audio. sound_entry
    # must check the tile's own attachment, not only image.audio_files, or a
    # parent's recorded custom audio would silently never get bundled.
    #
    # The Image's own audio and the tile's custom audio are attached here
    # with DELIBERATELY DIFFERENT, non-default content_types (identify: false
    # so ActiveStorage keeps exactly what's passed instead of sniffing the
    # actual mp3 bytes) so the assertion below can prove the emitted
    # content_type is the tile's own ("audio/mp4"), not the shared Image's
    # ("audio/wav") and not a hardcoded "audio/mpeg" default that happens to
    # match by accident.
    it "bundles the tile's own custom audio, not just the shared image's, with its own content_type" do
      image = create(:image, label: "apple", user: user)
      image.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: "apple-tts.wav", content_type: "audio/wav", identify: false,
      )
      doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)
      tile = board.board_images.create!(image_id: image.id, position: board.board_images.count,
                                        skip_create_voice_audio: true)
      tile.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: "apple-custom.m4a", content_type: "audio/mp4", identify: false,
      )
      doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                       filename: "tile.png", content_type: "image/png")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      sound_assets = result.assets.select { |a| a.kind == :sound }
      expect(sound_assets.size).to eq(1)
      sound = result.obf["sounds"].first
      expect(sound[:path]).to match(%r{\Asounds/.+\.m4a\z})
      expect(sound[:content_type]).to eq("audio/mp4")
    end

    # Regression: to_obf_button_format only emits btn[:sound_id] when
    # audio_url.present?, but every other spec in this describe block stubs
    # audio_url to nil via the top-level `before` block — so a bundled sound
    # with NO button pointing at it would sail through every other test here
    # undetected. This test overrides the stub with a genuinely present
    # audio_url (any_instance_of, not the local `tile` var, since
    # `board.reload` fetches fresh BoardImage instances that the exporter
    # actually iterates) and proves end-to-end that a bundled sound is
    # reachable from its button's sound_id.
    it "wires a bundled sound to its button's sound_id when audio_url is genuinely present" do
      allow_any_instance_of(BoardImage).to receive(:audio_url).and_return("https://example.test/apple.mp3")
      tile = add_tile_with_audio("apple")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      button = result.obf["buttons"].find { |b| b[:id] == tile.id.to_s }
      expect(button[:sound_id]).to be_present

      sound = result.obf["sounds"].find { |s| s[:id] == button[:sound_id] }
      expect(sound).to be_present
    end
  end

  describe "sound bundling (asset_mode: :inline)" do
    def add_tile_with_audio(label, filename: "line.mp3")
      image = create(:image, label: label, user: user)
      image.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: filename, content_type: "audio/mpeg",
      )
      doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)
      doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                       filename: "tile.png", content_type: "image/png")
      board.board_images.create!(image_id: image.id, position: board.board_images.count,
                                 skip_create_voice_audio: true)
    end

    # Regression: the :inline branch used to call to_obf_sound_format(mode:
    # :package, path: nil), which never took the package branch (it requires
    # path.present?) and fell through to the plain :url branch instead —
    # producing a self-contradictory entry with url + a hardcoded
    # content_type ("audio/aac") + a merged-in data field all at once. A
    # proper :inline mode must emit ONLY data (no url) with the real
    # content_type.
    it "emits data only (no url) with the real content_type, not the hardcoded audio/aac default" do
      add_tile_with_audio("apple")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :inline).call

      sound = result.obf["sounds"].first
      expect(sound[:data]).to be_present
      expect(sound).not_to have_key(:url)
      expect(sound[:content_type]).to eq("audio/mpeg")
    end
  end

  describe "inline-mode caps (sync .obf download path)" do
    it "raises TooLarge before doing any work when the board has more tiles than the cap" do
      stub_const("Boards::ObfExporter::MAX_INLINE_TILES", 1)
      add_tile("apple")
      add_tile("banana")

      expect {
        described_class.new(board.reload, exporting_user: user, asset_mode: :inline).call
      }.to raise_error(Boards::ObfExporter::TooLarge, /tile/i)
    end

    it "does not apply the tile cap to the :package or :url asset modes" do
      stub_const("Boards::ObfExporter::MAX_INLINE_TILES", 1)
      add_tile("apple")
      add_tile("banana")

      expect {
        described_class.new(board.reload, exporting_user: user, asset_mode: :package).call
      }.not_to raise_error
      expect {
        described_class.new(board.reload, exporting_user: user, asset_mode: :url).call
      }.not_to raise_error
    end

    it "raises TooLarge when accumulated inline bytes exceed the cap" do
      stub_const("Boards::ObfExporter::MAX_INLINE_BYTES", 10)
      add_tile("apple")

      expect {
        described_class.new(board.reload, exporting_user: user, asset_mode: :inline).call
      }.to raise_error(Boards::ObfExporter::TooLarge, /size/i)
    end
  end
end
