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
    # The zip path must come from the blob or it ends in a bare dot. Only
    # reachable now when there's no usable variant, since a variant-backed
    # asset takes its extension from the variant format instead.
    it "derives the asset extension from the attached blob when there is no usable variant" do
      add_tile("grandma")
      allow_any_instance_of(Doc).to receive(:tile_variant).and_return(nil)

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.assets.first.path).to match(%r{\Aimages/\d+\.png\z})
      expect(result.assets.first.variant).to be_nil
      expect(result.obf["images"].first[:content_type]).to eq("image/png")
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

  it "does not run one Board query per linked tile" do
    target_a = create(:board, user: user, name: "Drinks")
    target_b = create(:board, user: user, name: "Snacks")
    tile_a = add_tile("more")
    tile_a.update!(predictive_board_id: target_a.id)
    tile_b = add_tile("food")
    tile_b.update!(predictive_board_id: target_b.id)

    board_query_count = 0
    counter = ->(_name, _start, _finish, _id, payload) {
      board_query_count += 1 if payload[:sql].match?(/FROM "boards"/) && payload[:sql].match?(/WHERE "boards"."id" = /)
    }

    result = nil
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      result = described_class.new(board.reload, exporting_user: user).call
    end

    expect(board_query_count).to be <= 1
    expect(result.obf["buttons"].map { |b| b[:load_board][:name] }).to contain_exactly("Drinks", "Snacks")
  end

  it "does not run one user_docs query per tile" do
    add_tile("apple")
    add_tile("banana")
    add_tile("cherry")

    user_docs_query_count = 0
    counter = ->(_name, _start, _finish, _id, payload) {
      user_docs_query_count += 1 if payload[:sql].match?(/FROM "user_docs"/)
    }

    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      described_class.new(board.reload, exporting_user: user, asset_mode: :package).call
    end

    expect(user_docs_query_count).to eq(1)
  end

  # Fix 1 (final whole-branch review): sound_entry resolves
  # tile.current_audio_attachment || tile.image&.current_audio_attachment per
  # tile. Task 7's eager-load (`includes(:image, :board)`) never covered
  # either side's audio_files, so a multi-tile board with audio on every tile
  # ran one attachments/blobs query per tile despite the N+1 fix already
  # landing for boards/user_docs. The eager-load now also preloads both
  # records' audio_files_attachments/audio_files_blobs.
  it "does not run one attachment/blob query per tile for bundled audio" do
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

    tile_count = 3
    tile_count.times { |i| add_tile_with_audio("tile-#{i}") }

    # Bind values, not literal SQL text, carry which has_many_attached
    # association a query is for ("name" = 'audio_files' is a placeholder in
    # the logged SQL, not inlined) — so filter on the bound value rather than
    # the query string, which would also match the doc image lookups.
    audio_query_count = 0
    counter = ->(_name, _start, _finish, _id, payload) {
      next unless payload[:sql].match?(/FROM "active_storage_(attachments|blobs)"/)
      next unless (payload[:binds] || []).any? { |attr| attr.value.to_s == "audio_files" }

      audio_query_count += 1
    }

    result = nil
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call
    end

    expect(result.obf["sounds"].size).to eq(tile_count)
    # AudioHelper#current_audio_attachment's tile-own-audio branch calls
    # `audio_files.order(created_at: :desc).first`, which — unlike a plain
    # `.first` — always issues a fresh query and bypasses any preload
    # (a separate, documented AudioHelper gap, not this eager-load's target;
    # see the tracked follow-up issue). That contributes exactly one
    # unavoidable query PER TILE (`tile_count`), on top of a small FIXED
    # number of batched queries for the image-side fallback this eager-load
    # actually targets (one for audio_files_attachments, one for
    # audio_files_blobs — NOT one per tile). Before this fix, the image-side
    # fallback also fell back to a per-tile query, so the bound would have
    # scaled to roughly 2 * tile_count instead of tile_count + 2.
    expect(audio_query_count).to be <= tile_count + 2
  end

  # Board 5776's export failed at ObzPackager's 200MB cap: the package path
  # bundled full-resolution originals (665MB across its 23-board tree, vs
  # ~25MB of display-size variants). :package now resolves the same
  # display-size rendition :inline does.
  describe "display-size bundling (asset_mode: :package)" do
    it "bundles the webp tile variant, and describes it as webp everywhere" do
      add_tile("grandma")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call
      asset = result.assets.first

      expect(asset.path).to match(%r{\Aimages/\d+\.webp\z})
      expect(asset.variant).to be_present
      expect(result.obf["images"].first[:content_type]).to eq("image/webp")
      expect(result.obf["images"].first[:path]).to eq(asset.path)
    end

    # The variant bytes are what actually shrink the package. Asserting the
    # asset carries a variant is not enough — a variant that resolves to the
    # original's bytes would pass that and still blow the cap.
    it "carries bytes materially smaller than the original" do
      add_tile("grandma")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call
      asset = result.assets.first

      expect(asset.variant.download.bytesize).to be < asset.doc.image.download.bytesize
    end

    # The inverse of #inline_bytes_for's rule. :package runs in Sidekiq, so
    # transcoding an unprocessed variant here is background work — and it is
    # what keeps unprocessed docs from silently reintroducing originals.
    it "processes an unprocessed variant rather than falling back to the original" do
      add_tile("grandma")
      doc = board.reload.board_images.first.export_doc(user)
      expect(doc.tile_variant_processed?).to be(false)

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.assets.first.path).to end_with(".webp")
      expect(doc.reload.tile_variant_processed?).to be(true)
    end

    it "falls back to the original when variant processing fails" do
      add_tile("grandma")
      allow_any_instance_of(ActiveStorage::Variant).to receive(:processed).and_raise(StandardError, "vips exploded")
      allow_any_instance_of(ActiveStorage::VariantWithRecord).to receive(:processed)
        .and_raise(StandardError, "vips exploded")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call
      asset = result.assets.first

      expect(asset.variant).to be_nil
      expect(asset.path).to end_with(".png")
      expect(result.obf["images"].first[:content_type]).to eq("image/png")
    end
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

    # Fix 5 (final whole-branch review): the image path's asset_extension
    # already downcases; sound_entry didn't, so an uppercase-extension upload
    # produced an uppercase zip path — inconsistent with the image path's
    # behavior for no reason tied to file format.
    it "lowercases an uppercase filename extension in the zip path" do
      add_tile_with_audio("apple", filename: "RECORDING.MP3")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      sound = result.obf["sounds"].first
      expect(sound[:path]).to match(%r{\Asounds/\d+\.mp3\z})
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

    # The rendered 422 is identical for both caps, so the code is the only
    # thing that says which one fired.
    it "codes the two caps distinctly" do
      stub_const("Boards::ObfExporter::MAX_INLINE_TILES", 0)
      add_tile("apple")

      expect {
        described_class.new(board.reload, exporting_user: user, asset_mode: :inline).call
      }.to raise_error(an_object_having_attributes(code: "too_many_tiles"))

      stub_const("Boards::ObfExporter::MAX_INLINE_TILES", 200)
      stub_const("Boards::ObfExporter::MAX_INLINE_BYTES", 10)

      expect {
        described_class.new(board.reload, exporting_user: user, asset_mode: :inline).call
      }.to raise_error(an_object_having_attributes(code: "export_too_large"))
    end
  end

  describe "inline mode bundles display-size bytes" do
    def doc_for(label)
      Image.find_by(label: label).docs.last
    end

    def inline_images(exporter_user = user)
      described_class.new(board.reload, exporting_user: exporter_user, asset_mode: :inline).call.obf["images"]
    end

    it "bundles the processed tile variant rather than the full-resolution original" do
      add_tile("apple")
      doc = doc_for("apple")
      doc.tile_variant.processed

      entry = inline_images.first

      expect(entry[:content_type]).to eq("image/webp")
      expect(Base64.strict_decode64(entry[:data]).bytesize).to be < doc.image.download.bytesize
    end

    # Processing on demand would transcode inside the Puma worker, once per
    # tile — the original is the cheaper honest answer until the variant
    # exists.
    it "falls back to the original when the variant has not been processed yet" do
      add_tile("apple")
      doc = doc_for("apple")

      entry = inline_images.first

      expect(entry[:content_type]).to eq("image/png")
      expect(Base64.strict_decode64(entry[:data]).bytesize).to eq(doc.image.download.bytesize)
    end

    it "does not process the variant as a side effect of exporting" do
      add_tile("apple")

      expect { inline_images }.not_to change { doc_for("apple").tile_variant_processed? }.from(false)
    end

    it "still bundles the original when the variant record is unreadable" do
      add_tile("apple")
      allow_any_instance_of(Doc).to receive(:tile_variant_processed?).and_return(true)
      allow_any_instance_of(Doc).to receive(:tile_variant).and_raise(StandardError, "boom")

      entry = inline_images.first

      expect(entry[:content_type]).to eq("image/png")
      expect(entry[:data]).to be_present
    end

    context "when two tiles share one doc" do
      let!(:shared_doc) do
        image = create(:image, label: "apple", user: user)
        doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)
        doc.image.attach(io: File.open(Rails.root.join("public", "logo_bubble.png")),
                         filename: "tile.png", content_type: "image/png")
        2.times do |i|
          board.board_images.create!(image_id: image.id, position: i, skip_create_voice_audio: true)
        end
        doc
      end

      it "counts the shared bytes once against the size cap" do
        # Room for exactly one copy: without the dedupe the second tile's
        # identical bytes push the running total past the cap and 422 a board
        # that is well inside it.
        stub_const("Boards::ObfExporter::MAX_INLINE_BYTES", shared_doc.image.download.bytesize + 10)

        expect { inline_images }.not_to raise_error
      end

      it "encodes the shared bytes once and reuses them for both tiles" do
        entries = inline_images

        expect(entries.size).to eq(2)
        expect(entries.first[:data]).to eq(entries.last[:data])
      end
    end
  end
end
