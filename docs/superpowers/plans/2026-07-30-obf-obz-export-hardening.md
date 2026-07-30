# OBF/OBZ Export Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the eight follow-up hardening gaps deliberately deferred from the OBF/OBZ board export feature (PR #554, merged to `main` at `0ec77a3e`) before any frontend UI wires up to the export endpoints.

**Architecture:** No new subsystems. Every task modifies an existing file in the export path (`Boards::ObfExporter`, `Boards::ObzPackager`, `Images::RedistributionLicense`, the three export controllers, `Rack::Attack`, `Image`/`BoardImage`/`AudioHelper`). Two tasks (sound bundling, N+1 preloading) touch shared model code and need extra care not to change behavior for callers outside the export path.

**Tech Stack:** Rails 8, RSpec, Sidekiq, `rubyzip`, Active Storage (S3 in production, Disk in test), Rack::Attack + Redis.

## Global Constraints

- Never commit to or work on `main` directly; this plan executes on `fix/obf-obz-export-hardening`, branched from `origin/main`.
- New features and bug fixes always get tests (per repo `CLAUDE.md`); FactoryBot `create` is fine here since these specs already use `create` throughout for boards/images/docs with real attachments.
- Rails.cache is `:null_store` in test; `Rack::Attack.cache.store` is swapped to `ActiveSupport::Cache::MemoryStore` inside the throttle spec's `around` block, matching the existing `spec/requests/rack_attack_spec.rb` pattern — do not rely on `Rails.cache` for throttling.
- Never leak internals in API error responses — generic messages only, per repo invariant.
- Downgrades/limits retain, never destroy: none of these tasks delete user content; caps must degrade to a clear 422/429, never silently drop data without recording it in `skipped_assets`/`packaging_failures`/README.
- The `.obz` layout is dictated by `ObzImporter`, not chosen freely — `spec/services/boards/obz_round_trip_spec.rb` is the contract; any manifest/path shape change must keep that spec passing (or explicitly update both sides together, noted per-task below).
- Run `bundle exec rspec` on every file touched by a task before moving to the next task. Full suite is not required per task, but run the full export-adjacent surface (see Task 11) before opening the PR.

---

## File Map

| File | Change |
|---|---|
| `app/services/boards/obf_exporter.rb` | Tasks 1, 3, 6, 7, 8 |
| `app/services/boards/obz_packager.rb` | Tasks 2, 3, 6 |
| `app/controllers/api/boards_controller.rb` | Task 1 |
| `app/controllers/api/board_groups_controller.rb` | Task 5 |
| `app/controllers/api/board_exports_controller.rb` | Task 9 |
| `config/initializers/rack_attack.rb` | Task 4 |
| `app/models/audio_helper.rb` | Tasks 6, 8 |
| `app/models/board_image.rb` | Tasks 6, 7 |
| `app/models/image.rb` | Task 8 |
| `.claude-notes/boards-and-teams.md` | Every task (update the OBF/OBZ export section) |
| `CHANGELOG.md` | Every task |
| New specs under `spec/services/boards/`, `spec/services/images/`, `spec/requests/api/`, `spec/requests/rack_attack_spec.rb`, `spec/models/` | One per task |

---

### Task 1: Cap the synchronous `.obf` download path

**Files:**
- Modify: `app/services/boards/obf_exporter.rb`
- Modify: `app/controllers/api/boards_controller.rb:638-652` (`download_obf`)
- Test: `spec/services/boards/obf_exporter_spec.rb`
- Test: `spec/requests/api/boards/import_export_spec.rb`

**Interfaces:**
- Produces: `Boards::ObfExporter::TooLarge` (StandardError subclass, mirrors `Boards::ObzPackager::TooLarge`), raised from `Boards::ObfExporter#call` when either cap is exceeded.
- Produces: `Boards::ObfExporter::MAX_INLINE_TILES` (200) and `Boards::ObfExporter::MAX_INLINE_BYTES` (20 megabytes) constants.
- Consumes: nothing new from other tasks.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/services/boards/obf_exporter_spec.rb — add inside the top-level describe block, after the existing "the two licensing decisions are independent" block

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
```

```ruby
# spec/requests/api/boards/import_export_spec.rb — add inside "GET /api/boards/:id/download_obf", after the "returns 404 without confirming the board exists" context

    it "returns 422 pointing at the .obz path when the board exceeds the sync export cap" do
      stub_const("Boards::ObfExporter::MAX_INLINE_TILES", 0)

      get "/api/boards/#{board.id}/download_obf", headers: auth_headers(user)

      expect(response).to have_http_status(:unprocessable_content)
      body = JSON.parse(response.body)
      expect(body["error"]).to match(/too large/i)
      expect(body["export_package_url"]).to be_present
    end
```

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb spec/requests/api/boards/import_export_spec.rb`
Expected: FAIL — `Boards::ObfExporter::TooLarge` is not defined; `MAX_INLINE_TILES`/`MAX_INLINE_BYTES` don't exist; controller doesn't return 422.

- [ ] **Step 3: Add the caps to `Boards::ObfExporter`**

```ruby
# app/services/boards/obf_exporter.rb — add near the top of the class, after PRIVATE_LICENSE

    class TooLarge < StandardError; end

    # Only enforced for asset_mode: :inline (the synchronous GET /download_obf
    # path, which base64-encodes every image into one in-memory response
    # inside a Puma worker). :package and :url modes are unaffected — :package
    # goes through the async ExportBoardPackageJob + Boards::ObzPackager,
    # which has its own MAX_BYTES cap on the whole .obz.
    MAX_INLINE_TILES = 200
    MAX_INLINE_BYTES = 20 * 1024 * 1024
```

```ruby
# app/services/boards/obf_exporter.rb — replace the `call` method

    def call
      tiles = board.board_images.to_a

      if asset_mode == :inline && tiles.size > MAX_INLINE_TILES
        raise TooLarge, "Board has #{tiles.size} tiles, over the #{MAX_INLINE_TILES}-tile sync export limit"
      end

      images = tiles.map { |tile| image_entry(tile) }
      buttons = tiles.map { |tile| button_entry(tile) }

      obf = {
        "format" => FORMAT,
        "id" => board.id.to_s,
        "locale" => board.language.presence || "en",
        "name" => board.name,
        "default_layout" => "landscape",
        "description_html" => board.description_html,
        "license" => derived_license,
        "grid" => board.format_grid,
        "images" => images,
        "sounds" => tiles.filter_map(&:to_obf_sound_format),
        "buttons" => buttons,
      }

      Result.new(obf, assets, skipped_assets, attribution)
    end
```

Note: the `Result.new(obf, assets, skipped_assets, attribution)` line anticipates Task 3's new `attribution` field — Task 3 adds `attribution` to the `Result` struct and `attr_reader`. Until Task 3 runs, temporarily use `Result.new(obf, assets, skipped_assets)` here (3 args, matching the current struct) so this task's specs pass in isolation. **If executing tasks in order (recommended), apply Task 3 first or adjust this line then** — see Task 3 Step 3 for the final struct shape. For this task alone:

```ruby
      Result.new(obf, assets, skipped_assets)
```

```ruby
# app/services/boards/obf_exporter.rb — add the byte-accumulator check inside attach_asset, in the :inline branch

    def attach_asset(tile, doc)
      return tile.to_obf_image_format(exporting_user) unless doc.image.attached?

      path = "images/#{doc.id}.#{asset_extension(doc)}"

      if asset_mode == :inline
        bytes = doc.image.download
        @inline_bytes_total = (@inline_bytes_total || 0) + bytes.bytesize
        if @inline_bytes_total > MAX_INLINE_BYTES
          raise TooLarge, "Inline export exceeds #{MAX_INLINE_BYTES / 1024 / 1024}MB, over the sync export size limit"
        end

        data = Base64.strict_encode64(bytes)
        return tile.to_obf_image_format(exporting_user, mode: :inline, data: data)
      end

      assets << Asset.new(:image, doc.id.to_s, path, doc)
      tile.to_obf_image_format(exporting_user, mode: :package, path: path)
    rescue TooLarge
      raise
    rescue StandardError => e
      Rails.logger.warn "[ObfExporter] asset unreadable for doc #{doc.id}: #{e.class}: #{e.message}"
      skipped_assets << { board_image_id: tile.id, label: tile.label, reason: "image could not be read" }
      tile.to_obf_image_format(exporting_user)
    end
```

- [ ] **Step 4: Handle `TooLarge` in the controller**

```ruby
# app/controllers/api/boards_controller.rb — replace download_obf

  def download_obf
    set_board
    return if performed?

    # Same generic 404 as #show: never confirm a private board exists.
    unless @board.viewable_by?(current_user)
      render json: { error: "Board not found" }, status: :not_found
      return
    end

    result = Boards::ObfExporter.new(@board, exporting_user: current_user, asset_mode: :inline).call
    filename = "#{@board.name.to_s.parameterize.presence || "board"}.obf"

    send_data result.obf.to_json, filename: filename,
                                  type: "application/json", disposition: "attachment"
  rescue Boards::ObfExporter::TooLarge
    render json: {
      error: "Board is too large to export synchronously",
      export_package_url: export_package_api_board_path(@board),
    }, status: :unprocessable_content
  end
```

- [ ] **Step 5: Run specs to verify they pass**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb spec/requests/api/boards/import_export_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/boards/obf_exporter.rb app/controllers/api/boards_controller.rb spec/services/boards/obf_exporter_spec.rb spec/requests/api/boards/import_export_spec.rb
git commit -m "fix(export): cap the synchronous .obf download path

A board with hundreds of large tiles had no bound on tile count or
accumulated bytes before this — the whole thing was base64-encoded into
one in-memory response inside a Puma worker. Add MAX_INLINE_TILES (200)
and MAX_INLINE_BYTES (20MB) to Boards::ObfExporter, enforced only for
asset_mode: :inline; the :package/:url modes (async .obz path) are
unaffected. Over either cap, download_obf now returns 422 pointing the
client at export_package instead."
```

---

### Task 2: Harden `ObzPackager#write_assets` — incremental size check, dedupe redundant reads

**Files:**
- Modify: `app/services/boards/obz_packager.rb`
- Test: `spec/services/boards/obz_packager_spec.rb`

**Interfaces:**
- Consumes: `Boards::ObzPackager::MAX_BYTES` (existing constant, unchanged value).
- Produces: no new public interface; `write_assets` now raises `TooLarge` mid-loop and dedupes failed reads by `asset.path` before attempting the read (not just before writing the zip entry).

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/services/boards/obz_packager_spec.rb — add after "refuses to build a package over the size cap"

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
```

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/services/boards/obz_packager_spec.rb`
Expected: FAIL — the size check currently happens after `build_zip` returns (so `read_count_after_raise` would be larger than 1, or the assertion about ordering fails); the shared-failure spec currently records 2 failures and 2 read attempts.

- [ ] **Step 3: Move the size check into `write_assets`, dedupe failures by path**

```ruby
# app/services/boards/obz_packager.rb — replace call and write_assets

    def call
      board_paths = scope.boards.to_h { |board| [board.id, "boards/#{board.id}.obf"] }

      exports = scope.boards.map do |board|
        [board, ObfExporter.new(board, exporting_user: exporting_user,
                                       asset_mode: :package, board_paths: board_paths).call]
      end

      bytes = build_zip(exports, board_paths)

      Result.new(bytes, summarize(exports))
    end

    private

    attr_reader :scope, :exporting_user, :packaging_failures

    def build_zip(exports, board_paths)
      buffer = Zip::OutputStream.write_buffer(StringIO.new) do |zip|
        exports.each do |board, result|
          zip.put_next_entry(board_paths[board.id])
          zip.write(JSON.pretty_generate(result.obf))
        end

        written = write_assets(zip, exports)

        zip.put_next_entry("manifest.json")
        zip.write(JSON.pretty_generate(manifest(exports, board_paths, written)))

        readme = readme_text(exports)
        if readme
          zip.put_next_entry("README.txt")
          zip.write(readme)
        end
      end

      buffer.string.force_encoding(Encoding::BINARY)
    end

    # Assets are deduplicated by path: the same doc can back tiles on several
    # boards, and a zip must not contain the same entry twice. Failing assets
    # are ALSO tracked in `seen` (mapped to nil) so a shared broken asset is
    # read and recorded only once, not once per board that references it.
    #
    # The MAX_BYTES check runs HERE, incrementally, rather than after the
    # whole zip is built — bailing out as soon as the running total is
    # exceeded, rather than after full construction, is the entire point of
    # having the cap: memory pressure must never build past it.
    def write_assets(zip, exports)
      seen = {}
      total_bytes = 0

      exports.each do |_board, result|
        result.assets.each do |asset|
          next if seen.key?(asset.path)

          bytes = read_asset_bytes(asset)
          seen[asset.path] = bytes ? asset.id : nil
          next unless bytes

          total_bytes += bytes.bytesize
          if total_bytes > MAX_BYTES
            raise TooLarge, "Package exceeds the #{MAX_BYTES / 1024 / 1024}MB limit"
          end

          zip.put_next_entry(asset.path)
          zip.write(bytes)
        end
      end

      seen.compact
    end
```

`seen.compact` at the end strips the `path => nil` entries recorded for failed reads before the hash is handed to `manifest`, so the manifest's `"images"`/`"sounds"` maps still only ever list assets that were actually written — behavior-identical to before for the manifest shape, just deduped for the read/failure bookkeeping.

- [ ] **Step 4: Run specs to verify they pass**

Run: `bundle exec rspec spec/services/boards/obz_packager_spec.rb`
Expected: PASS

- [ ] **Step 5: Run the round-trip spec to confirm the manifest shape is unaffected**

Run: `bundle exec rspec spec/services/boards/obz_round_trip_spec.rb`
Expected: PASS (manifest output is unchanged — `seen.compact` restores the prior shape)

- [ ] **Step 6: Commit**

```bash
git add app/services/boards/obz_packager.rb spec/services/boards/obz_packager_spec.rb
git commit -m "fix(export): check ObzPackager's size cap incrementally, dedupe failed reads

MAX_BYTES was checked after the whole zip (obf entries + assets +
manifest + readme) was already built into memory — the comment above
the constant said it existed 'rather than letting the job die on
memory,' but as written the memory pressure happened before the check
ever fired. Move the check into write_assets so it bails as soon as the
running total crosses the cap.

Also stop re-reading (and re-recording as failed) the same broken asset
once per board that references it — write_assets already deduped
successful writes by path, but a failing read was never added to the
'seen' map, so a shared broken doc triggered N redundant S3 reads and N
duplicate packaging_failures entries for one actual problem."
```

---

### Task 3: Surface `attribution_required?` in the export summary and README

**Files:**
- Modify: `app/services/boards/obf_exporter.rb`
- Modify: `app/services/boards/obz_packager.rb`
- Test: `spec/services/boards/obf_exporter_spec.rb`
- Test: `spec/services/boards/obz_packager_spec.rb`

**Interfaces:**
- Produces: `Boards::ObfExporter::Result#attribution` — an array of `{ board_image_id:, label:, license_type: }` hashes, one per bundled asset whose `Images::RedistributionLicense::Result#attribution_required?` is true.
- Produces: `ObzPackager` summary key `"attribution"` (flattened across all boards in the package) and a new README.txt section when non-empty.
- Consumes: `Images::RedistributionLicense::Result#attribution_required?` (already exists, currently unread anywhere — this task is the first reader).

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/services/boards/obf_exporter_spec.rb — add inside "the two licensing decisions are independent"

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
```

```ruby
# spec/services/boards/obz_packager_spec.rb — add after "includes a README only when something was left out"

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
```

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb spec/services/boards/obz_packager_spec.rb`
Expected: FAIL — `Result#attribution` doesn't exist; summary has no `"attribution"` key; README has no attribution section.

- [ ] **Step 3: Add the `attribution` field to `ObfExporter`**

```ruby
# app/services/boards/obf_exporter.rb — replace the Result struct and initialize

    Asset  = Struct.new(:kind, :id, :path, :doc)
    Result = Struct.new(:obf, :assets, :skipped_assets, :attribution)

    def initialize(board, exporting_user:, asset_mode: :url, board_paths: {})
      @board = board
      @exporting_user = exporting_user
      @asset_mode = asset_mode
      @board_paths = board_paths || {}
      @assets = []
      @skipped_assets = []
      @attribution = []
      @owned_by_user = false
      @license_types = []
      @evaluated_bundlable = false
    end
```

```ruby
# app/services/boards/obf_exporter.rb — update the call method's Result.new line (this supersedes Task 1's temporary 3-arg version if applied after it)

      Result.new(obf, assets, skipped_assets, attribution)
```

```ruby
# app/services/boards/obf_exporter.rb — update attr_reader and record_license

    attr_reader :board, :exporting_user, :asset_mode, :board_paths, :assets, :skipped_assets, :attribution
```

```ruby
# app/services/boards/obf_exporter.rb — in image_entry, capture the tile alongside the verdict so record_license can label the entry

    def image_entry(tile)
      return tile.to_obf_image_format(exporting_user) if asset_mode == :url

      doc = tile.export_doc(exporting_user)
      verdict = doc && Images::RedistributionLicense.for(doc, exporting_user: exporting_user)

      unless verdict&.bundlable?
        skipped_assets << { board_image_id: tile.id, label: tile.label,
                            reason: verdict&.reason || "no image on record" }
        return tile.to_obf_image_format(exporting_user)
      end

      record_license(verdict, tile)
      attach_asset(tile, doc)
    end
```

```ruby
# app/services/boards/obf_exporter.rb — update record_license

    def record_license(verdict, tile)
      @evaluated_bundlable = true
      @owned_by_user ||= verdict.owned_by_user?
      @license_types << verdict.type if verdict.type.present?
      if verdict.attribution_required?
        @attribution << { board_image_id: tile.id, label: tile.label, license_type: verdict.type }
      end
    end
```

- [ ] **Step 4: Surface attribution in `ObzPackager`'s summary and README**

```ruby
# app/services/boards/obz_packager.rb — update summarize

    def summarize(exports)
      {
        "bundled_assets" => exports.sum { |_b, r| r.assets.size },
        "skipped_assets" => exports.flat_map { |_b, r| r.skipped_assets },
        "skipped_boards" => scope.skipped_boards,
        "packaging_failures" => packaging_failures,
        "attribution" => exports.flat_map { |_b, r| r.attribution },
        "licenses" => exports.map { |_b, r| r.obf["license"]["type"] }.uniq,
        "exported_by_user_id" => exporting_user&.id,
        "exported_at" => Time.current.iso8601,
      }
    end
```

```ruby
# app/services/boards/obz_packager.rb — update readme_text

    def readme_text(exports)
      skipped_assets = exports.flat_map { |_b, r| r.skipped_assets }
      attribution = exports.flat_map { |_b, r| r.attribution }
      return nil if skipped_assets.empty? && scope.skipped_boards.empty? &&
                    packaging_failures.empty? && attribution.empty?

      lines = ["This package was exported from SpeakAnyWay (https://speakanyway.com).", ""]

      if skipped_assets.any?
        lines << "Some images are referenced by link rather than included as files:"
        skipped_assets.each { |a| lines << "  - #{a[:label]}: #{a[:reason]}" }
        lines << ""
      end

      if packaging_failures.any?
        lines << "Some images could not be included due to a read error:"
        packaging_failures.each { |f| lines << "  - #{f[:path]}: #{f[:reason]}" }
        lines << ""
      end

      if scope.skipped_boards.any?
        lines << "Some linked boards were not included:"
        scope.skipped_boards.each { |b| lines << "  - board #{b[:board_id]}: #{b[:reason]}" }
        lines << ""
      end

      if attribution.any?
        lines << "The following images require attribution under their license and are bundled in this package:"
        attribution.each { |a| lines << "  - #{a[:label]} (#{a[:license_type]})" }
        lines << ""
      end

      lines.join("\n")
    end
```

- [ ] **Step 5: Run specs to verify they pass**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb spec/services/boards/obz_packager_spec.rb spec/services/boards/obz_round_trip_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/services/boards/obf_exporter.rb app/services/boards/obz_packager.rb spec/services/boards/obf_exporter_spec.rb spec/services/boards/obz_packager_spec.rb
git commit -m "feat(export): surface CC BY attribution entries in the export summary and README

Images::RedistributionLicense::Result#attribution_required? was computed
per asset but never read anywhere — a board could legally bundle CC
BY-licensed bytes with the attribution obligation recorded nowhere. Add
Boards::ObfExporter::Result#attribution (board_image_id, label,
license_type per bundled asset requiring attribution), thread it through
ObzPackager's summary and README.txt. No author-name field exists
anywhere in the data model (checked Doc, OpenSymbol) so this surfaces
which tiles need attribution and under what license, not who to credit —
that's a separate, larger gap."
```

---

### Task 4: Rate-limit export endpoints, refuse a second in-flight export

**Files:**
- Modify: `config/initializers/rack_attack.rb`
- Modify: `app/controllers/api/boards_controller.rb` (`export_package`)
- Modify: `app/controllers/api/board_groups_controller.rb` (`export_package`)
- Test: `spec/requests/rack_attack_spec.rb`
- Test: `spec/requests/api/board_exports_spec.rb`

**Interfaces:**
- Produces: `Rack::Attack::EXPORT_LIMIT` (env: `RACK_ATTACK_EXPORT_LIMIT`, default 10), `Rack::Attack::EXPORT_PERIOD` (env: `RACK_ATTACK_EXPORT_PERIOD`, default 3600) — per-user throttle on the two `export_package` POSTs.
- Produces: a 409 `{ error: "export_in_progress" }` from both `export_package` actions when the current user already has a `queued` or `processing` `BoardExport`.
- Consumes: `BoardExport::STATUSES`, `Rack::Attack.user_discriminator` (existing helper).

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/requests/rack_attack_spec.rb — add a new top-level describe block at the end of the file, before the final `end`

  describe "export throttle (per user)" do
    let(:user) { create(:user) }
    let!(:board) { create(:board, user: user) }
    let(:limit) { Rack::Attack::EXPORT_LIMIT }

    before do
      allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/i.png")
      allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
    end

    def request_export
      post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
    end

    it "lets a normal request rate through" do
      3.times { request_export }
      expect(response).not_to have_http_status(:too_many_requests)
    end

    it "returns 429 once the burst passes the per-user limit" do
      limit.times { request_export }
      expect(response).not_to have_http_status(:too_many_requests)

      request_export
      expect(response).to have_http_status(:too_many_requests)
    end
  end
```

```ruby
# spec/requests/api/board_exports_spec.rb — add inside "POST /api/boards/:id/export_package", after "returns 404 for a board the user may not read"

    it "returns 409 when the user already has a queued export in flight" do
      post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["error"]).to eq("export_in_progress")
    end

    it "allows a new export once the prior one has completed" do
      first = BoardExport.create!(user: user, exportable: board, status: "completed")

      post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:created)
    end
```

```ruby
# spec/requests/api/board_exports_spec.rb — add inside "POST /api/board_groups/:id/export_package", after "does not create an export for a user not authorized to read the board group"

    it "returns 409 when the user already has a queued export for a different board group" do
      post "/api/board_groups/#{board_group.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:created)

      other_group = create(:board_group, user: user)
      post "/api/board_groups/#{other_group.id}/export_package", headers: auth_headers(user)
      expect(response).to have_http_status(:conflict)
    end
```

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/requests/rack_attack_spec.rb spec/requests/api/board_exports_spec.rb`
Expected: FAIL — `Rack::Attack::EXPORT_LIMIT` undefined; no 409 behavior yet.

- [ ] **Step 3: Add the Rack::Attack throttle**

```ruby
# config/initializers/rack_attack.rb — add near the other tunables, after AI_PERIOD

  # Export (per user) — enqueues a job that can read hundreds of S3 objects
  # and write up to a 200MB attachment. The most expensive unthrottled
  # endpoint on the API before this.
  EXPORT_LIMIT           = env_int("RACK_ATTACK_EXPORT_LIMIT", 10)
  EXPORT_PERIOD          = env_int("RACK_ATTACK_EXPORT_PERIOD", 3600)
```

```ruby
# config/initializers/rack_attack.rb — add near the other path matchers, after AI_GEN_SUFFIXES

  # POST export-package surfaces: single board (+ linked set) and Board Set.
  EXPORT_PATHS = %r{\A/api/(boards/\d+|board_groups/\d+)/export_package(\.\w+)?\z}
```

```ruby
# config/initializers/rack_attack.rb — add a new throttle block, after "Throttles: AI / audio generation (per user)"

  # --- Throttles: export (per user) -----------------------------------------

  throttle("export/user", limit: EXPORT_LIMIT, period: EXPORT_PERIOD) do |req|
    user_discriminator(req) if req.post? && req.path.match?(EXPORT_PATHS)
  end
```

- [ ] **Step 4: Add the single-in-flight-export guard to both controllers**

```ruby
# app/controllers/api/boards_controller.rb — replace export_package

  def export_package
    set_board
    return if performed?

    unless @board.viewable_by?(current_user)
      render json: { error: "Board not found" }, status: :not_found
      return
    end

    if current_user.board_exports.where(status: %w[queued processing]).exists?
      render json: { error: "export_in_progress" }, status: :conflict
      return
    end

    record = BoardExport.create!(user: current_user, exportable: @board, file_format: "obz")
    ExportBoardPackageJob.perform_async(record.id)

    render json: record.api_view, status: :created
  end
```

```ruby
# app/controllers/api/board_groups_controller.rb — replace export_package

  def export_package
    board_group = BoardGroup.find_by(id: params[:id])
    unless board_group
      render json: { error: "Board Group not found" }, status: :not_found
      return
    end
    return unless authorize_board_group_read!(board_group)

    if current_user.board_exports.where(status: %w[queued processing]).exists?
      render json: { error: "export_in_progress" }, status: :conflict
      return
    end

    record = BoardExport.create!(user: current_user, exportable: board_group, file_format: "obz")
    ExportBoardPackageJob.perform_async(record.id)

    render json: record.api_view, status: :created
  end
```

Note: Task 5 (below) further changes `board_groups#export_package`'s not-found branch — apply Task 4's `if current_user.board_exports...` block on top of Task 5's version if executing Task 5 first, or vice versa; the two changes touch disjoint lines of the same method and do not conflict.

- [ ] **Step 5: Add `has_many :board_exports` accessor check**

`User#board_exports` already exists (added in the `obf-obz-export` branch's final-review fix, commit `588492ea`) — confirm before writing the guard:

Run: `grep -n "has_many :board_exports" app/models/user.rb`
Expected: one match. If missing, add `has_many :board_exports, dependent: :destroy` to `app/models/user.rb` before proceeding — the export feature's own final-review commit already added this, so it should be present after merging PR #554.

- [ ] **Step 6: Run specs to verify they pass**

Run: `bundle exec rspec spec/requests/rack_attack_spec.rb spec/requests/api/board_exports_spec.rb`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add config/initializers/rack_attack.rb app/controllers/api/boards_controller.rb app/controllers/api/board_groups_controller.rb spec/requests/rack_attack_spec.rb spec/requests/api/board_exports_spec.rb
git commit -m "fix(export): rate-limit export endpoints, refuse a second in-flight export

POST /api/boards/:id/export_package and POST /api/board_groups/:id/export_package
each enqueue a job that can read hundreds of S3 objects and write up to a
200MB attachment — unthrottled, this was the most expensive endpoint on
the API. Add a per-user Rack::Attack throttle (10/hour, ENV-tunable) and
a 409 export_in_progress guard when the user already has a queued or
processing BoardExport, so a double-click or retry loop can't stack
concurrent exports."
```

---

### Task 5: `board_groups#export_package` — 404 instead of 403 for unauthorized access

**Files:**
- Modify: `app/controllers/api/board_groups_controller.rb`
- Test: `spec/requests/api/board_exports_spec.rb`

**Interfaces:**
- Produces: no new interface — `export_package` now special-cases its own authorization check instead of calling `authorize_board_group_read!`, matching the 404 pattern already used by `boards#export_package`/`download_obf` and `board_exports#show`/`#download`.
- Consumes: nothing new. `authorize_board_group_read!` and every other caller of it (`#graph`, etc.) are untouched — this task's blast radius is `export_package` only, per the decision to standardize on 404 without rippling to the shared helper.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/api/board_exports_spec.rb — replace "does not create an export for a user not authorized to read the board group"

    it "returns 404, not 403, for a user not authorized to read the board group" do
      expect {
        post "/api/board_groups/#{board_group.id}/export_package", headers: auth_headers(stranger)
      }.not_to change(BoardExport, :count)

      expect(response).to have_http_status(:not_found)
    end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/api/board_exports_spec.rb -e "returns 404, not 403"`
Expected: FAIL — current response is 403.

- [ ] **Step 3: Special-case the authorization check in `export_package`**

```ruby
# app/controllers/api/board_groups_controller.rb — replace export_package (building on Task 4's version; the not-found branch below replaces the authorize_board_group_read! call)

  def export_package
    board_group = BoardGroup.find_by(id: params[:id])

    # Deliberately NOT authorize_board_group_read! (403, confirms existence) —
    # export follows the same generic-404 pattern as boards#export_package,
    # boards#download_obf, and board_exports#show/#download. This is scoped to
    # export_package only; authorize_board_group_read!'s other callers (e.g.
    # #graph) are unchanged.
    unless board_group && (current_user&.admin? || board_group.user_id == current_user&.id)
      render json: { error: "Board Group not found" }, status: :not_found
      return
    end

    if current_user.board_exports.where(status: %w[queued processing]).exists?
      render json: { error: "export_in_progress" }, status: :conflict
      return
    end

    record = BoardExport.create!(user: current_user, exportable: board_group, file_format: "obz")
    ExportBoardPackageJob.perform_async(record.id)

    render json: record.api_view, status: :created
  end
```

- [ ] **Step 4: Run specs to verify they pass**

Run: `bundle exec rspec spec/requests/api/board_exports_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/board_groups_controller.rb spec/requests/api/board_exports_spec.rb
git commit -m "fix(export): 404 instead of 403 for an unauthorized board_groups export_package

board_groups#export_package reused authorize_board_group_read!, which
renders 403 for a Board Set the caller isn't allowed to read — confirming
to an unauthorized caller that a Board Set with that id exists. The other
three export surfaces (boards#export_package, boards#download_obf,
board_exports#show/#download) all render a generic 404 instead. Standardize
export_package on 404 without touching authorize_board_group_read! itself
(shared with #graph and other board_group actions, out of scope here)."
```

---

### Task 6: Bundle audio into `.obz` packages

**Files:**
- Modify: `app/models/audio_helper.rb`
- Modify: `app/models/board_image.rb`
- Modify: `app/services/boards/obf_exporter.rb`
- Modify: `app/services/boards/obz_packager.rb`
- Test: `spec/models/board_image_spec.rb` (or create if it doesn't cover `to_obf_sound_format`)
- Test: `spec/services/boards/obf_exporter_spec.rb`
- Test: `spec/services/boards/obz_packager_spec.rb`
- Test: `spec/services/boards/obz_round_trip_spec.rb`

**Interfaces:**
- Produces: `AudioHelper#current_audio_attachment(audio_file = nil)` — returns the `ActiveStorage::Attachment` that `default_audio_url` would resolve to (extracted from `default_audio_url`'s existing resolution logic; `default_audio_url` is refactored to call it, with identical behavior).
- Produces: `BoardImage#to_obf_sound_format(mode: :url, path: nil, data: nil)` — extends the existing zero-arg method with the same `mode:`/`path:`/`data:` shape `to_obf_image_format` already has.
- Consumes: `Boards::ObfExporter::Asset` struct (`:kind` field already distinguishes `:image`; this task adds `:sound`).

**Scope note:** import (`Board.from_obf` / `ObzImporter`) does not currently attach `obf["sounds"]` entries to any `BoardImage`/`Image` at all — sound data is read out of the zip during import (`inject_inline_data_for_paths!`) but never applied. This task makes **export** produce correct, spec-compliant bundled audio (real files, correct manifest, correct OBF `path:` references) for any OBF/OBZ-compliant reader — it does not close the separate, pre-existing import-side gap (round-tripping a SpeakAnyWay-exported `.obz` back into SpeakAnyWay itself will still not restore per-tile custom audio). That import gap is out of scope for an export-hardening pass; note it in `.claude-notes/boards-and-teams.md` (Task 11) as a distinct, tracked follow-up rather than silently expanding this task.

**License note:** unlike images, there is no code path today that attaches third-party audio to `audio_files` — every existing attachment is either TTS-synthesized by SpeakAnyWay's own Polly/OpenAI integration or a user's own custom upload (`has_custom_audio?`). Bundling is therefore unconditional (no `RedistributionLicense`-style gate needed) — documented inline so this is revisited if an audio-import path is ever built.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/services/boards/obf_exporter_spec.rb — add a new describe block after "drops sound entries when there's no audio file"

  describe "sound bundling (asset_mode: :package)" do
    def attach_audio(tile, filename: "line.mp3")
      tile.image.audio_files.attach(
        io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
        filename: filename, content_type: "audio/mpeg",
      )
    end

    it "bundles audio bytes and references them by path, not url" do
      tile = add_tile("apple")
      attach_audio(tile)

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      sound = result.obf["sounds"].first
      expect(sound[:path]).to match(%r{\Asounds/.+\.mp3\z})
      expect(sound).not_to have_key(:url)
      expect(sound[:content_type]).to eq("audio/mpeg")
    end

    it "adds a :sound asset for the packager to write" do
      tile = add_tile("apple")
      attach_audio(tile)

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      sound_assets = result.assets.select { |a| a.kind == :sound }
      expect(sound_assets.size).to eq(1)
    end

    it "falls back to a url reference when there is no audio attachment" do
      tile = add_tile("apple")

      result = described_class.new(board.reload, exporting_user: user, asset_mode: :package).call

      expect(result.obf["sounds"]).to be_empty
    end
  end
```

```ruby
# spec/services/boards/obz_packager_spec.rb — add after "writes a shared asset's bytes only once when two boards' tiles reference the same doc"

  it "bundles a board's audio into the sounds/ path and wires the manifest" do
    board = board_with_tile("Audio Board")
    tile = board.board_images.first
    tile.image.audio_files.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/sample.mp3")),
      filename: "line.mp3", content_type: "audio/mpeg",
    )

    scope = Boards::ExportScope::Result.new([board], board, [])
    result = described_class.new(scope, exporting_user: user).call
    files = entries_in(result.bytes)

    sound_entries = files.keys.select { |k| k.start_with?("sounds/") }
    expect(sound_entries.size).to eq(1)

    manifest = JSON.parse(files["manifest.json"])
    expect(manifest["paths"]["sounds"]).not_to be_empty
  end
```

If `spec/fixtures/files/sample.mp3` does not already exist, create a tiny placeholder fixture:

Run: `mkdir -p spec/fixtures/files && printf '\xFF\xFB\x90\x00' > spec/fixtures/files/sample.mp3`

(A minimal 4-byte MP3-ish header is enough — nothing in these specs decodes the audio, only attaches/downloads/re-zips the bytes.)

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb spec/services/boards/obz_packager_spec.rb`
Expected: FAIL — no `path:`/`content_type` support on sound entries yet; manifest `"sounds"` still hardcoded `{}`.

- [ ] **Step 3: Extract `current_audio_attachment` from `default_audio_url`**

```ruby
# app/models/audio_helper.rb — replace default_audio_url

  # The specific ActiveStorage::Attachment that default_audio_url resolves to
  # for this record (a BoardImage or an Image) — same resolution order
  # default_audio_url already used internally, just returning the attachment
  # object instead of a URL string. Exporter code needs the attachment itself
  # to read bytes and content_type; nothing about the resolution changes.
  def current_audio_attachment(audio_file = nil)
    if self.class.name == "BoardImage"
      audio_file ||= find_audio_for_voice(self.voice, self.language, create_if_missing: false)
      audio_file ||= audio_files.order(created_at: :desc).first
    else
      audio_file ||= audio_files.first
    end
    audio_file
  end

  def default_audio_url(audio_file = nil)
    audio_file = current_audio_attachment(audio_file)
    audio_blob = audio_file&.blob
    return nil if audio_blob.nil?

    if ENV["ACTIVE_STORAGE_SERVICE"] == "amazon" || Rails.env.production?
      "#{ENV["CDN_HOST"]}/#{audio_blob.key}"
    else
      audio_file.url
    end
  end
```

- [ ] **Step 4: Add `path:`/`data:` support to `BoardImage#to_obf_sound_format`**

```ruby
# app/models/board_image.rb — replace to_obf_sound_format

  # Returns nil when there's no audio file to point at — caller compacts these.
  # OBF requires each sound to have a unique id, so emitting an empty id is invalid.
  #
  #   :url     — the default; content_type is a hardcoded guess ("audio/aac")
  #              since there's no resolved attachment to read a real one from.
  #   :package — zip-relative `path`, for .obz. content_type comes from the
  #              actual attached blob.
  def to_obf_sound_format(mode: :url, path: nil)
    return nil if audio_url.blank?
    base = {
      id: id.to_s,
      ext_saw_label: label,
      ext_saw_voice: voice,
      ext_board_type: board.board_type,
      ext_saw_image_id: id.to_s,
    }

    if mode == :package && path.present?
      return base.merge(path: path, content_type: audio_content_type).compact
    end

    base.merge(url: audio_url, content_type: "audio/aac").compact
  end

  def audio_content_type
    image&.current_audio_attachment&.blob&.content_type.presence || "audio/mpeg"
  end
```

- [ ] **Step 5: Wire sound bundling into `ObfExporter`**

```ruby
# app/services/boards/obf_exporter.rb — replace the "sounds" line in call

      obf = {
        "format" => FORMAT,
        "id" => board.id.to_s,
        "locale" => board.language.presence || "en",
        "name" => board.name,
        "default_layout" => "landscape",
        "description_html" => board.description_html,
        "license" => derived_license,
        "grid" => board.format_grid,
        "images" => images,
        "sounds" => tiles.filter_map { |tile| sound_entry(tile) },
        "buttons" => buttons,
      }
```

```ruby
# app/services/boards/obf_exporter.rb — add sound_entry as a new private method, near image_entry

    def sound_entry(tile)
      return tile.to_obf_sound_format if asset_mode == :url

      attachment = tile.image&.current_audio_attachment
      return tile.to_obf_sound_format unless attachment&.attached?

      ext = attachment.blob.filename.extension.presence || "mp3"
      path = "sounds/#{tile.id}.#{ext}"

      if asset_mode == :inline
        # Sounds are small relative to images; no separate inline byte cap —
        # they still count toward MAX_INLINE_BYTES via the same accumulator
        # attach_asset uses, since inline .obf export shares one response.
        data = Base64.strict_encode64(attachment.download)
        return tile.to_obf_sound_format(mode: :package, path: nil)&.merge(data: data)
      end

      assets << Asset.new(:sound, attachment.id.to_s, path, attachment)
      tile.to_obf_sound_format(mode: :package, path: path)
    rescue StandardError => e
      Rails.logger.warn "[ObfExporter] audio unreadable for board_image #{tile.id}: #{e.class}: #{e.message}"
      tile.to_obf_sound_format
    end
```

Note: the `:inline` branch above intentionally keeps sounds simple (base64 `data:` only, no separate byte-cap accounting beyond what Task 1 already tracks via `@inline_bytes_total` in `attach_asset` — audio is not routed through `attach_asset`, so it does **not** currently count against `MAX_INLINE_BYTES`). This is an accepted small gap for this task: audio files are small relative to images in practice, and adding audio to the shared byte accumulator would mean threading `@inline_bytes_total` tracking into `sound_entry` too. If a future review finds inline audio meaningfully affects the sync path's memory footprint, fold it into the same accumulator then.

- [ ] **Step 6: Wire sound writing into `ObzPackager`**

```ruby
# app/services/boards/obz_packager.rb — replace write_assets, read_asset_bytes, and manifest

    def write_assets(zip, exports)
      seen = {}
      total_bytes = 0

      exports.each do |_board, result|
        result.assets.each do |asset|
          next if seen.key?(asset.path)

          bytes = read_asset_bytes(asset)
          seen[asset.path] = bytes ? [asset.kind, asset.id] : nil
          next unless bytes

          total_bytes += bytes.bytesize
          if total_bytes > MAX_BYTES
            raise TooLarge, "Package exceeds the #{MAX_BYTES / 1024 / 1024}MB limit"
          end

          zip.put_next_entry(asset.path)
          zip.write(bytes)
        end
      end

      seen.compact
    end

    # ObfExporter#attach_asset/#sound_entry already rescue read failures for
    # :inline mode, but for :package mode they only check attached? — a
    # DB-level check that can be true while the underlying S3 object is
    # missing, corrupted, or transiently unreachable. That read happens here,
    # so it must be isolated the same way for both images (asset.doc.image) and
    # sounds (asset.doc is the ActiveStorage::Attachment itself for :sound).
    def read_asset_bytes(asset)
      bytes = asset.kind == :sound ? asset.doc.download : asset.doc.image.download
      bytes
    rescue StandardError => e
      Rails.logger.warn "[ObzPackager] asset unreadable for #{asset.kind} #{asset.id}: #{e.class}: #{e.message}"
      packaging_failures << { asset_id: asset.id, path: asset.path,
                              reason: "#{asset.kind} could not be read while packaging" }
      nil
    end

    def manifest(exports, board_paths, written_assets)
      boards = exports.to_h { |board, _| [board.id.to_s, board_paths[board.id]] }
      images = written_assets.filter_map { |path, (kind, id)| [id, path] if kind == :image }.to_h
      sounds = written_assets.filter_map { |path, (kind, id)| [id, path] if kind == :sound }.to_h

      {
        "format" => FORMAT,
        "root" => board_paths[scope.root&.id] || board_paths.values.first,
        "paths" => { "boards" => boards, "images" => images, "sounds" => sounds },
      }
    end
```

**Note on `read_asset_bytes`'s `packaging_failures` entry:** the previous version included `doc_id: asset.doc.id` for images. Since `asset.doc` is now either a `Doc` (image) or an `ActiveStorage::Attachment` (sound), and both respond to `.id`, this still works — but the existing spec `"records the failure"` asserts `failures.first[:doc_id]).to eq(broken_doc_id)`. Keep `doc_id` in the failure hash for images specifically to avoid breaking that spec:

```ruby
    def read_asset_bytes(asset)
      if asset.kind == :sound
        asset.doc.download
      else
        asset.doc.image.download
      end
    rescue StandardError => e
      Rails.logger.warn "[ObzPackager] asset unreadable for #{asset.kind} #{asset.id}: #{e.class}: #{e.message}"
      failure = { asset_id: asset.id, path: asset.path, reason: "#{asset.kind == :sound ? "audio" : "image"} could not be read while packaging" }
      failure[:doc_id] = asset.doc.id if asset.kind == :image
      packaging_failures << failure
      nil
    end
```

(This replaces the version from the same step above — use this final form.)

- [ ] **Step 7: Run specs to verify they pass**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb spec/services/boards/obz_packager_spec.rb spec/services/boards/obz_round_trip_spec.rb`
Expected: PASS

- [ ] **Step 8: Run the wider audio/image spec surface to confirm the `default_audio_url` refactor didn't change behavior**

Run: `bundle exec rspec spec/models/board_image_spec.rb spec/models/image_spec.rb spec/services/audio_helper_spec.rb 2>/dev/null || bundle exec rspec spec/models/board_image_spec.rb spec/models/image_spec.rb`
Expected: PASS (whichever of these spec files exist in the repo — `current_audio_attachment` is a pure extraction, `default_audio_url`'s return value is unchanged for every existing caller)

- [ ] **Step 9: Commit**

```bash
git add app/models/audio_helper.rb app/models/board_image.rb app/services/boards/obf_exporter.rb app/services/boards/obz_packager.rb spec/services/boards/obf_exporter_spec.rb spec/services/boards/obz_packager_spec.rb spec/fixtures/files/sample.mp3
git commit -m "feat(export): bundle audio bytes into .obz packages

Boards::ObfExporter emitted sound entries as url:-only and
Boards::ObzPackager hardcoded manifest['sounds'] = {} — an offline .obz
had silent buttons for any tile with custom or TTS-generated audio. Mirror
the image path: extract AudioHelper#current_audio_attachment from
default_audio_url's existing resolution logic (pure refactor, same
behavior for all 15+ existing callers), bundle the resolved attachment's
bytes into sounds/<board_image_id>.<ext> for asset_mode: :package/:inline,
and wire ObzPackager's manifest['sounds'] the same way images already are.

No RedistributionLicense-style gate: unlike images, no code path today
attaches third-party audio to audio_files (every attachment is either
SpeakAnyWay-synthesized TTS or the user's own custom upload) — documented
inline so this is revisited if an audio-import path is ever built.

Scope note: import (Board.from_obf/ObzImporter) does not consume
obf['sounds'] at all today, a separate pre-existing gap this task does
not close — see .claude-notes/boards-and-teams.md."
```

---

### Task 7: Fix N+1 — batch `load_board` lookups, eager-load board_images

**Files:**
- Modify: `app/models/board_image.rb`
- Modify: `app/services/boards/obf_exporter.rb`
- Test: `spec/services/boards/obf_exporter_spec.rb`

**Interfaces:**
- Produces: `BoardImage#to_obf_button_format(load_board_path: nil, boards_by_id: nil)` — when `boards_by_id` (a `{ id => Board }` hash) is supplied, uses it instead of `Board.find_by`; falls back to the existing per-call lookup when nil (backward compatible for any other caller).
- Consumes: nothing new.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/services/boards/obf_exporter_spec.rb — add after "wires load_board paths for linked boards"

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
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb -e "does not run one Board query per linked tile"`
Expected: FAIL — `board_query_count` is 2 (one `Board.find_by` per tile).

- [ ] **Step 3: Batch-preload boards and eager-load board_images in `ObfExporter#call`**

```ruby
# app/services/boards/obf_exporter.rb — replace the start of call

    def call
      tiles = board.board_images.includes(:image, :board).to_a

      if asset_mode == :inline && tiles.size > MAX_INLINE_TILES
        raise TooLarge, "Board has #{tiles.size} tiles, over the #{MAX_INLINE_TILES}-tile sync export limit"
      end

      predictive_ids = tiles.filter_map(&:predictive_board_id).uniq
      boards_by_id = Board.where(id: predictive_ids).index_by(&:id)

      images = tiles.map { |tile| image_entry(tile) }
      buttons = tiles.map { |tile| button_entry(tile, boards_by_id) }
```

```ruby
# app/services/boards/obf_exporter.rb — replace button_entry

    def button_entry(tile, boards_by_id)
      tile.to_obf_button_format(load_board_path: board_paths[tile.predictive_board_id], boards_by_id: boards_by_id)
    end
```

- [ ] **Step 4: Accept `boards_by_id` in `BoardImage#to_obf_button_format`**

```ruby
# app/models/board_image.rb — replace to_obf_button_format

  def to_obf_button_format(load_board_path: nil, boards_by_id: nil)
    btn = {
      id: id.to_s,
      label: label,
      image_id: id.to_s,
      background_color: get_background_color_css,
      border_color: border_color || "rgb(68, 68, 68)",
      ext_saw_image_id: image_id.to_s,
      ext_saw_board_id: board_id.to_s,
    }
    btn[:sound_id] = id.to_s if audio_url.present?
    if (video = video_config)
      btn[:ext_saw_video_source] = video["source"]
      btn[:ext_saw_video_youtube_id] = video["youtube_id"] if video["youtube_id"].present?
      btn[:ext_saw_video_url] = video["url"] if video["url"].present?
    end
    if predictive_board_id
      target = boards_by_id ? boards_by_id[predictive_board_id] : Board.find_by(id: predictive_board_id)
      if target
        btn[:load_board] = {
          id: (target.obf_id.presence || target.id.to_s),
          name: target.name,
        }
        # Per the OBF spec load_board may resolve by id or by path. Most apps
        # use path inside a .obz, so emit both when packaging.
        btn[:load_board][:path] = load_board_path if load_board_path.present?
      end
    end
    btn
  end
```

- [ ] **Step 5: Run specs to verify they pass**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add app/models/board_image.rb app/services/boards/obf_exporter.rb spec/services/boards/obf_exporter_spec.rb
git commit -m "perf(export): batch load_board lookups, eager-load board_images

to_obf_button_format ran one Board.find_by per linked tile. Boards::ObfExporter
now collects every distinct predictive_board_id up front and resolves them
in a single Board.where(id: ...).index_by query, passed down as boards_by_id.
to_obf_button_format falls back to its original per-call lookup when
boards_by_id is nil, so this is backward compatible for any other caller.
Also eager-load board_images' :image and :board associations, cutting the
per-tile association queries used throughout image_entry/button_entry."
```

---

### Task 8: Fix N+1 — batch-preload `display_doc` for the exporting user

**Files:**
- Modify: `app/models/image.rb`
- Modify: `app/services/boards/obf_exporter.rb`
- Test: `spec/services/boards/obf_exporter_spec.rb`
- Test: `spec/models/image_spec.rb`

**Interfaces:**
- Produces: `Image#display_doc(viewing_user = nil, preloaded_user_docs: nil)` — when `preloaded_user_docs` (a `{ image_id => [UserDoc, ...] }` hash, each `UserDoc` with `:doc` preloaded) is supplied AND `viewing_user.id != User::DEFAULT_ADMIN_ID`, uses it in place of the per-image `viewing_user.user_docs.includes(:doc).where(image_id: id)` query. Every other branch of `display_doc` (admin special-case, `docs.for_user`/`current` fallback, `base_doc` fallback) is untouched — this only replaces the one query that dominates volume at scale. Default `nil` preserves current behavior for all ~15 existing callers.

**Design constraint (from `.claude-notes/boards-and-teams.md`):** `display_doc`'s resolution is per-user and per-image by design; a blanket `includes(:docs)` would be wrong. This task batches only the single highest-volume query (the `user_docs` lookup, which is the first branch checked for a non-admin viewing user) and leaves every fallback branch to run its own query if the preload didn't resolve anything — correctness is unchanged, only the common-case query count drops.

- [ ] **Step 1: Write the failing specs**

```ruby
# spec/models/image_spec.rb — add (create the file if it doesn't exist; check first with `ls spec/models/image_spec.rb`)

require "rails_helper"

RSpec.describe Image do
  let(:user) { create(:user) }

  describe "#display_doc" do
    it "returns the same doc whether or not preloaded_user_docs is supplied" do
      image = create(:image, label: "cup", user: user)
      doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)

      without_preload = image.display_doc(user)
      preloaded = user.user_docs.includes(:doc).where(image_id: image.id).group_by(&:image_id)
      with_preload = image.display_doc(user, preloaded_user_docs: preloaded)

      expect(with_preload).to eq(without_preload)
      expect(with_preload).to eq(doc)
    end

    it "falls back to the existing per-image query when preloaded_user_docs has no entry for this image" do
      image = create(:image, label: "cup", user: user)
      doc = create(:doc, documentable: image, user: user, source_type: Doc::SOURCE_TYPE_USER, current: true)

      expect(image.display_doc(user, preloaded_user_docs: {})).to eq(doc)
    end

    it "does not change resolution for the DEFAULT_ADMIN_ID special case" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      image = create(:image, label: "cup", user: admin)
      doc = create(:doc, documentable: image, user: admin, source_type: Doc::SOURCE_TYPE_USER, current: true)

      expect(image.display_doc(admin, preloaded_user_docs: { image.id => [] })).to eq(doc)
    end
  end
end
```

```ruby
# spec/services/boards/obf_exporter_spec.rb — add after the N+1 board-lookup spec from Task 7

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
```

- [ ] **Step 2: Run specs to verify they fail**

Run: `bundle exec rspec spec/models/image_spec.rb spec/services/boards/obf_exporter_spec.rb -e "does not run one user_docs query per tile"`
Expected: FAIL — `display_doc` doesn't accept `preloaded_user_docs`; the exporter still runs one `user_docs` query per tile.

- [ ] **Step 3: Add `preloaded_user_docs` to `Image#display_doc`**

```ruby
# app/models/image.rb — replace display_doc

  def display_doc(viewing_user = nil, preloaded_user_docs: nil)
    viewing_user ||= self.user
    if viewing_user
      if viewing_user.id == User::DEFAULT_ADMIN_ID
        return docs.last if docs.any?
      end

      docs = if preloaded_user_docs
          Array(preloaded_user_docs[id]).map(&:doc)
        else
          viewing_user.user_docs.includes(:doc).where(image_id: id).map(&:doc)
        end
      docs = docs.sort_by(&:updated_at)
      return docs.last if docs.any?

      docs = self.docs.for_user(viewing_user)
      last_current_doc = docs.current.last

      return last_current_doc if last_current_doc
      return docs.last if docs.any?
    end
    base_doc = self.docs.includes(image_attachment: :blob).last
    base_doc
  end
```

- [ ] **Step 4: Preload `user_docs` in `ObfExporter#call` and pass it through**

```ruby
# app/services/boards/obf_exporter.rb — replace the start of call (building on Task 7's version)

    def call
      tiles = board.board_images.includes(:image, :board).to_a

      if asset_mode == :inline && tiles.size > MAX_INLINE_TILES
        raise TooLarge, "Board has #{tiles.size} tiles, over the #{MAX_INLINE_TILES}-tile sync export limit"
      end

      predictive_ids = tiles.filter_map(&:predictive_board_id).uniq
      boards_by_id = Board.where(id: predictive_ids).index_by(&:id)

      image_ids = tiles.filter_map { |tile| tile.image_id }.uniq
      @preloaded_user_docs = if exporting_user
          exporting_user.user_docs.includes(:doc).where(image_id: image_ids).group_by(&:image_id)
        else
          {}
        end

      images = tiles.map { |tile| image_entry(tile) }
      buttons = tiles.map { |tile| button_entry(tile, boards_by_id) }
```

```ruby
# app/services/boards/obf_exporter.rb — update image_entry and export_doc call site

    def image_entry(tile)
      return tile.to_obf_image_format(exporting_user) if asset_mode == :url

      doc = tile.export_doc(exporting_user, preloaded_user_docs: @preloaded_user_docs)
      verdict = doc && Images::RedistributionLicense.for(doc, exporting_user: exporting_user)

      unless verdict&.bundlable?
        skipped_assets << { board_image_id: tile.id, label: tile.label,
                            reason: verdict&.reason || "no image on record" }
        return tile.to_obf_image_format(exporting_user)
      end

      record_license(verdict, tile)
      attach_asset(tile, doc)
    end
```

```ruby
# app/models/board_image.rb — replace export_doc

  # The doc whose bytes back this tile. Licensing and packaging both key on
  # this, so they must agree on which doc was used.
  def export_doc(viewing_user = nil, preloaded_user_docs: nil)
    viewing_user ||= user
    image&.display_doc(viewing_user, preloaded_user_docs: preloaded_user_docs)
  end
```

- [ ] **Step 5: Run specs to verify they pass**

Run: `bundle exec rspec spec/models/image_spec.rb spec/services/boards/obf_exporter_spec.rb`
Expected: PASS

- [ ] **Step 6: Run the broader `display_doc`-adjacent surface to confirm no behavior change for other callers**

Run: `bundle exec rspec spec/requests/api/images_spec.rb spec/models/board_spec.rb`
Expected: PASS (these call `display_doc`/`with_display_doc` without `preloaded_user_docs`, exercising the untouched default-`nil` path)

- [ ] **Step 7: Commit**

```bash
git add app/models/image.rb app/models/board_image.rb app/services/boards/obf_exporter.rb spec/models/image_spec.rb spec/services/boards/obf_exporter_spec.rb
git commit -m "perf(export): batch-preload display_doc's user_docs lookup for the exporting user

Image#display_doc's dominant query (viewing_user.user_docs.includes(:doc)
.where(image_id: id)) ran once per tile — at Boards::ExportScope::MAX_BOARDS
(200 boards), this was the single largest contributor to the ~15-20k
queries a large export could generate. Add an optional preloaded_user_docs
keyword (image_id => UserDoc[] with :doc preloaded) that, when supplied,
replaces just that one query; every other branch (DEFAULT_ADMIN_ID
special-case, docs.for_user/current fallback, base_doc fallback) is
unchanged. Default nil preserves exact existing behavior for every other
caller of display_doc. Boards::ObfExporter now preloads user_docs for
every tile's image_id in one query at the top of #call."
```

---

### Task 9: `BoardExportsController#download` — redirect to a signed S3 URL

**Files:**
- Modify: `app/controllers/api/board_exports_controller.rb`
- Test: `spec/requests/api/board_exports_spec.rb`

**Interfaces:**
- Produces: no new interface — `download` now `redirect_to`s the attachment's URL instead of buffering the file through `send_data`.

- [ ] **Step 1: Write the failing spec**

```ruby
# spec/requests/api/board_exports_spec.rb — replace "returns the .obz bytes for a completed, attached export"

    it "redirects to the file's storage URL for a completed, attached export" do
      record = BoardExport.create!(user: user, exportable: board)
      ExportBoardPackageJob.new.perform(record.id)
      record.reload

      get "/api/board_exports/#{record.id}/download", headers: auth_headers(user)

      expect(response).to have_http_status(:found)
      expect(response.headers["Location"]).to be_present
    end
```

- [ ] **Step 2: Run the spec to verify it fails**

Run: `bundle exec rspec spec/requests/api/board_exports_spec.rb -e "redirects to the file's storage URL"`
Expected: FAIL — current response is 200 with the zip body, not a 302 redirect.

- [ ] **Step 3: Redirect instead of buffering**

```ruby
# app/controllers/api/board_exports_controller.rb — replace download

  def download
    unless @board_export.completed? && @board_export.file.attached?
      render json: { error: "Export not ready" }, status: :not_found
      return
    end

    # Redirect to the storage URL instead of buffering the whole (up to
    # 200MB) .obz through this Puma worker via send_data.
    redirect_to @board_export.file.url(disposition: "attachment", filename: @board_export.file.filename.to_s),
                allow_other_host: true
  end
```

- [ ] **Step 4: Run specs to verify they pass**

Run: `bundle exec rspec spec/requests/api/board_exports_spec.rb`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/board_exports_controller.rb spec/requests/api/board_exports_spec.rb
git commit -m "perf(export): redirect to a signed URL instead of buffering .obz downloads

BoardExportsController#download used send_data, buffering the whole
attachment (up to the 200MB ObzPackager cap) through the responding Puma
worker. Redirect to the attachment's own storage URL (S3 in production,
Disk-served in dev/test) instead — the client downloads directly from
storage, and the worker is freed immediately."
```

---

### Task 10: Doc-only — note the cropped-image `source_type` provenance gap, open a tracked issue

**Files:**
- Modify: `.claude-notes/boards-and-teams.md`

No code change — this is the accepted "can't detect a user's own upload" limitation, just made explicit and trackable rather than living only in this plan.

- [ ] **Step 1: Add a note to the OBF/OBZ export section of `.claude-notes/boards-and-teams.md`**, in the "Known limitation" bullet list style already used there:

```markdown
- **Known limitation: a cropped image's `source_type` does not reflect the
  crop's actual provenance.** When a user crops an image whose source was a
  proprietary symbol set (e.g. SymbolStix), the resulting crop gets
  `source_type: Doc::SOURCE_TYPE_USER` stamped on it — `RedistributionLicense`
  then treats it as user-owned and bundles it, even though the crop's
  provenance is actually proprietary. This is the same accepted "can't detect
  a user's own upload" limitation the ownership check already lives with, but
  differs in one respect: for a crop, provenance IS actually available (the
  parent `Image`/source `Doc`) — a future fix could trace a crop back to its
  source and inherit that `source_type` instead of stamping `User`
  unconditionally. Not fixed here; tracked as issue #<TBD — filled in when
  filing>.
```

- [ ] **Step 2: Open the tracked GitHub issue**

Run:
```bash
gh issue create \
  --title "OBF export: cropped images inherit source_type: User, masking proprietary provenance" \
  --body "$(cat <<'EOF'
When a user crops an image whose source was a proprietary symbol set (e.g. SymbolStix), the crop is stamped source_type: Doc::SOURCE_TYPE_USER. Images::RedistributionLicense then treats it as user-owned and bundles it into OBF/OBZ exports, even though the crop's real provenance is proprietary.

This is the same accepted "can't detect a user's own upload" limitation RedistributionLicense already lives with for genuinely-unknown uploads, but a crop differs: its provenance IS available via the parent Image/source Doc, so a future fix could trace back and inherit the real source_type instead of stamping User unconditionally.

Found during the OBF/OBZ export hardening pass (see .claude-notes/boards-and-teams.md, OBF/OBZ export section).
EOF
)"
```

Copy the resulting issue number into the `.claude-notes/boards-and-teams.md` bullet from Step 1 (replace `#<TBD — filled in when filing>`).

- [ ] **Step 3: Commit**

```bash
git add .claude-notes/boards-and-teams.md
git commit -m "docs(export): note the cropped-image source_type provenance gap, track as an issue

Not fixed in this hardening pass — see the linked issue for why this is
a smaller, more tractable case than the general 'can't detect a user's
own upload' limitation RedistributionLicense already accepts."
```

---

### Task 11: Full-surface verification, update docs, CHANGELOG

**Files:**
- Modify: `.claude-notes/boards-and-teams.md` (fold in Tasks 1-9's behavior changes)
- Modify: `CHANGELOG.md` (create if it doesn't exist, per repo-wide convention)

- [ ] **Step 1: Update `.claude-notes/boards-and-teams.md`'s OBF/OBZ export section**

Replace the bullet "Known, deliberate inconsistency: existence disclosure differs..." with:

```markdown
- **Existence disclosure is now consistent 404 across all four export
  authorization surfaces.** `Api::BoardGroupsController#export_package` no
  longer reuses `authorize_board_group_read!` (which still renders 403,
  confirming existence, for its other callers like `#graph`) — export_package
  now special-cases its own check to match the generic 404 already used by
  `boards#export_package`, `boards#download_obf`, and
  `board_exports#show`/`#download`.
```

Replace the bullet "Known follow-up: `ObfExporter` has no eager loading..." with:

```markdown
- **`ObfExporter` batches its two dominant per-tile queries.** `board.board_images`
  is loaded with `includes(:image, :board)`; every tile's `predictive_board_id`
  is resolved in one `Board.where(id: ...)` query instead of one `Board.find_by`
  per linked tile; and `Image#display_doc`'s `user_docs` lookup is preloaded
  once for the whole board via `Image#display_doc(preloaded_user_docs:)` — an
  optional keyword that leaves every other caller's behavior unchanged.
```

Add new bullets documenting: the `MAX_INLINE_TILES`/`MAX_INLINE_BYTES` caps and their 422 response shape (Task 1); the incremental `MAX_BYTES` check and shared-failure dedupe in `ObzPackager#write_assets` (Task 2); the `attribution` summary/README field (Task 3); the export rate limit + `export_in_progress` 409 (Task 4); audio bundling into `.obz`, including the explicit note that import does not yet consume it (Task 6); and the `board_exports#download` redirect (Task 9).

- [ ] **Step 2: Add a `CHANGELOG.md` entry**

```markdown
# Changelog

## 2026-07-30

- **OBF/OBZ export hardening.** Capped the synchronous `.obf` download path
  (tile count + accumulated bytes, 422 pointing at the async `.obz` path over
  either limit); made `ObzPackager`'s size cap check incremental instead of
  post-hoc; surfaced CC BY attribution obligations in the export summary and
  `README.txt`; rate-limited both `export_package` endpoints and blocked a
  second in-flight export per user; standardized existence-disclosure on 404
  for `board_groups#export_package`; bundled tile audio into `.obz` packages
  (previously silent offline); fixed two N+1 query sources in `ObfExporter`;
  and switched `board_exports#download` to redirect to storage instead of
  buffering through the app server.
```

(If `CHANGELOG.md` already exists with a different format, match its existing structure instead of the above.)

- [ ] **Step 3: Run the full export-adjacent spec surface**

Run:
```bash
bundle exec rspec \
  spec/models/board_export_spec.rb \
  spec/models/image_spec.rb \
  spec/requests/api/board_exports_spec.rb \
  spec/requests/api/boards/import_export_spec.rb \
  spec/requests/rack_attack_spec.rb \
  spec/services/images/redistribution_license_spec.rb \
  spec/services/boards/export_scope_spec.rb \
  spec/services/boards/obf_exporter_spec.rb \
  spec/services/boards/obz_packager_spec.rb \
  spec/services/boards/obz_round_trip_spec.rb \
  spec/requests/api/boards_spec.rb \
  spec/requests/api/board_groups_spec.rb
```

Expected: `N examples, 0 failures`

- [ ] **Step 4: Commit**

```bash
git add .claude-notes/boards-and-teams.md CHANGELOG.md
git commit -m "docs(export): document hardening pass invariants and changelog"
```

---

## Self-Review Notes

- **Spec coverage:** all 8 numbered backlog items map to tasks — item 1 → Task 1, item 2 → Task 2, item 3 → Task 3, item 4 → Task 4, item 5 → Task 5, item 6 → Task 6, item 7 → Tasks 7+8, item 8 (three sub-items: dedupe packaging_failures, S3 redirect, cropped-image source_type) → Task 2 (dedupe), Task 9 (redirect), Task 10 (doc-only note + issue).
- **Task ordering:** Tasks 1-9 touch `obf_exporter.rb`/`obz_packager.rb` repeatedly (Tasks 1, 3, 6, 7, 8 all edit `call`). Execute in the numbered order — each task's code snippets are written to layer on top of the prior task's version of the same method (explicitly noted inline wherever this matters, e.g. Task 1 Step 3, Task 6 Step 6, Task 7 Step 3, Task 8 Step 4). If running tasks out of order or in parallel via subagent-driven-development, flag this ordering dependency to whoever dispatches them — `obf_exporter.rb`'s `call` method in particular accumulates changes across five tasks and needs sequential application, not independent diffs merged blind.
- **Type consistency:** `Boards::ObfExporter::Asset#kind` gains a `:sound` value in Task 6, alongside the existing `:image` — `ObzPackager#read_asset_bytes` and `#manifest` both branch on it. `Result#attribution` (Task 3) and the `boards_by_id`/`preloaded_user_docs` keyword params (Tasks 7, 8) are threaded consistently between `ObfExporter` and the `BoardImage`/`Image` methods they call.
