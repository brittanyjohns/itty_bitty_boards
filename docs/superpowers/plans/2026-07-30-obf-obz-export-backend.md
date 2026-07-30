# OBF / OBZ Export — Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a user export a board as `.obf` and a board set (or a board plus its linked subtree) as `.obz`, bundling only assets we may lawfully redistribute.

**Architecture:** Three new service objects — `Images::RedistributionLicense` (may these bytes be bundled?), `Boards::ObfExporter` (one board → one OBF hash + an asset list), `Boards::ObzPackager` (boards + assets → a zip) — plus `Boards::ExportScope` to resolve what to export. Single-board `.obf` is synchronous; `.obz` runs in a Sidekiq job writing to a `BoardExport` record the client polls. The package layout deliberately mirrors what the existing `ObzImporter` reads, so export/import round-trip is structural.

**Tech Stack:** Rails 8, RSpec, Sidekiq, ActiveStorage (S3), rubyzip.

**Spec:** `docs/superpowers/specs/2026-07-30-obf-obz-export-design.md`

## Global Constraints

- Work on branch `obf-obz-export` in the worktree `.claude/worktrees/obf-obz-export`. Never commit to `main`.
- Ruby style: standard Ruby, no metaprogramming. Fat models, thin controllers. snake_case.
- **Do not install gems beyond `rubyzip`**, which is already a transitive dependency and is only being promoted to an explicit one (per repo `CLAUDE.md`: do not install new gems without asking — this one is pre-approved by the spec).
- Never expose internal errors in API responses — generic client-facing messages only.
- All new specs use `FactoryBot.build` over `create` where a DB row isn't needed.
- Licensing predicates **fail closed**: anything unrecognized is not bundlable.
- `spec/services/images/commercial_license_spec.rb` must stay green and unmodified throughout. It is the guard on Task 1's extraction.
- Run specs with `bundle exec rspec` from the worktree root.

---

## File Structure

| File | Responsibility |
|---|---|
| `app/services/images/license_resolution.rb` | **new** — the single place that knows where a license lives on a `Doc` and how to normalize it |
| `app/services/images/commercial_license.rb` | **modify** — delegate resolution to the above; behavior unchanged |
| `app/services/images/redistribution_license.rb` | **new** — may these bytes be bundled into a user's export? |
| `app/helpers/boards_helper.rb` | **modify** — fix `format_grid`; delete `to_obf` (moves to `ObfExporter`) |
| `app/models/board.rb` | **modify** — `license` becomes `export_license(exporting_user)`, derived |
| `app/models/board_image.rb` | **modify** — `to_obf_image_format` gains asset modes; `to_obf_button_format` gains `load_board.path` |
| `app/services/boards/obf_exporter.rb` | **new** — one board → `{ obf:, assets:, skipped_assets: }` |
| `app/services/boards/export_scope.rb` | **new** — request → `{ boards:, root:, skipped_boards: }` |
| `app/services/boards/obz_packager.rb` | **new** — boards + assets → zip bytes |
| `app/models/board_export.rb` | **new** — status + attached file + audit stamp |
| `db/migrate/20260730120000_create_board_exports.rb` | **new** |
| `app/sidekiq/export_board_package_job.rb` | **new** |
| `app/controllers/api/boards_controller.rb` | **modify** — fix `download_obf`; add `export_package` |
| `app/controllers/api/board_groups_controller.rb` | **modify** — add `export_package` |
| `app/controllers/api/board_exports_controller.rb` | **new** — poll + download |
| `config/routes.rb` | **modify** |
| `Gemfile` | **modify** — promote `rubyzip` to an explicit dependency |

---

## Task 1: Extract `Images::LicenseResolution`

Pure refactor. `Images::CommercialLicense` currently owns the only code that knows how to read a license off a `Doc` — including the OpenSymbol indirection, where the license lives on the symbol row rather than the doc. `RedistributionLicense` needs the same logic, so it moves to a shared module first. **No behavior change.**

**Files:**
- Create: `app/services/images/license_resolution.rb`
- Modify: `app/services/images/commercial_license.rb`
- Test: `spec/services/images/license_resolution_spec.rb`
- Guard (do not edit): `spec/services/images/commercial_license_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `Images::LicenseResolution.resolve(doc)` → jsonb `Hash`, license `String`, `:protected`, or `nil`
  - `Images::LicenseResolution.normalize_type(value)` → `String` (lowercased, whitespace-collapsed)
  - `Images::LicenseResolution.truthy?(value)` → `Boolean`

- [ ] **Step 1: Record the current behavior as a baseline**

Run: `bundle exec rspec spec/services/images/commercial_license_spec.rb`
Expected: PASS, 25 examples, 0 failures. Note the count — it must be identical at the end of this task.

- [ ] **Step 2: Write the failing test for the new module**

Create `spec/services/images/license_resolution_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Images::LicenseResolution do
  describe ".normalize_type" do
    it "lowercases and collapses whitespace" do
      expect(described_class.normalize_type("CC By-SA  3.0")).to eq("cc by-sa 3.0")
    end

    it "returns an empty string for nil" do
      expect(described_class.normalize_type(nil)).to eq("")
    end
  end

  describe ".truthy?" do
    it "accepts the string and boolean forms the symbol rows use" do
      expect(described_class.truthy?("true")).to be true
      expect(described_class.truthy?("T")).to be true
      expect(described_class.truthy?("1")).to be true
      expect(described_class.truthy?(true)).to be true
    end

    it "rejects everything else" do
      expect(described_class.truthy?("false")).to be false
      expect(described_class.truthy?(nil)).to be false
    end
  end

  describe ".resolve" do
    it "returns the doc's own license when present" do
      doc = Doc.new(license: { "type" => "CC BY" })
      expect(described_class.resolve(doc)).to eq({ "type" => "CC BY" })
    end

    it "returns nil for a doc with no license and a non-OpenSymbol source" do
      doc = Doc.new(source_type: "OpenAI")
      expect(described_class.resolve(doc)).to be_nil
    end

    it "returns :protected when any matching symbol is protected" do
      OpenSymbol.create!(search_string: "cup", license: "CC BY", protected_symbol: "true")
      doc = Doc.new(source_type: "OpenSymbol", raw: "cup")
      expect(described_class.resolve(doc)).to eq(:protected)
    end

    it "returns the symbol license when every matching symbol agrees" do
      OpenSymbol.create!(search_string: "dog", license: "CC BY", protected_symbol: "false")
      OpenSymbol.create!(search_string: "dog", license: "CC By", protected_symbol: "false")
      doc = Doc.new(source_type: "OpenSymbol", raw: "dog")
      expect(described_class.resolve(doc)).to eq("CC BY")
    end

    # search_string is a label match, not provenance: two symbols can share it
    # with different licenses. We cannot know which one this doc came from.
    it "returns nil when matching symbols disagree" do
      OpenSymbol.create!(search_string: "family", license: "CC BY-SA", protected_symbol: "false")
      OpenSymbol.create!(search_string: "family", license: "public domain", protected_symbol: "false")
      doc = Doc.new(source_type: "OpenSymbol", raw: "family")
      expect(described_class.resolve(doc)).to be_nil
    end
  end
end
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `bundle exec rspec spec/services/images/license_resolution_spec.rb`
Expected: FAIL — `uninitialized constant Images::LicenseResolution`

- [ ] **Step 4: Create the module**

Create `app/services/images/license_resolution.rb`:

```ruby
# app/services/images/license_resolution.rb
#
# The single place that knows where a license lives on a Doc and how to
# normalize it. Extracted from Images::CommercialLicense so the export
# predicate (Images::RedistributionLicense) reads licenses the same way.
#
# Grounded in the actual library (measured 2026-07-22, 10,101 docs). Two facts
# drive the shape of this code:
#
#   * Doc#license is the ONLY populated license field (Image#license has zero
#     rows) and its jsonb key is "type", not "license".
#   * Doc#license is populated only on ObfImport docs. OpenSymbol-sourced docs
#     carry their license on the OpenSymbol row instead.
module Images
  module LicenseResolution
    module_function

    # OpenSymbol docs keep their license on the symbol row, not the doc.
    # search_string has no uniqueness constraint and is a label match, NOT
    # provenance — more than one symbol can share it with different licenses
    # (e.g. "family - family, ,": one CC BY-SA, one public domain). We cannot
    # know which symbol this doc actually came from, so only trust the license
    # when every matching row agrees (after normalization); otherwise treat the
    # doc as having no usable license, which callers render as unsafe.
    #
    # Returns the jsonb hash, a license string, :protected, or nil.
    def resolve(doc)
      return doc.license if doc.license.present?
      return nil unless doc.source_type == "OpenSymbol"

      symbols = doc.matching_open_symbols.order(:id).to_a
      return nil if symbols.empty?
      return :protected if symbols.any? { |symbol| truthy?(symbol.protected_symbol) }

      normalized_licenses = symbols.map { |symbol| normalize_type(symbol.license) }.uniq
      return nil unless normalized_licenses.size == 1

      symbols.first.license
    end

    # "CC By-SA 3.0" -> "cc by-sa 3.0"; collapses whitespace so version
    # suffixes and casing inconsistencies in the library don't matter.
    def normalize_type(value)
      value.to_s.strip.downcase.gsub(/\s+/, " ")
    end

    def truthy?(value)
      ["true", "t", "1", true].include?(value.is_a?(String) ? value.downcase : value)
    end
  end
end
```

- [ ] **Step 5: Run the new test to verify it passes**

Run: `bundle exec rspec spec/services/images/license_resolution_spec.rb`
Expected: PASS, 8 examples, 0 failures

- [ ] **Step 6: Delegate from `CommercialLicense`**

In `app/services/images/commercial_license.rb`, inside `def for`, replace the first two lines of the method body:

```ruby
        # Resolved once — for OpenSymbol docs this hits the DB.
        license = resolve_license(doc)
```

with:

```ruby
        # Resolved once — for OpenSymbol docs this hits the DB.
        license = LicenseResolution.resolve(doc)
```

Then in the same method replace:

```ruby
        type = normalize_type(license.is_a?(Hash) ? license["type"] : license)
```

with:

```ruby
        type = LicenseResolution.normalize_type(license.is_a?(Hash) ? license["type"] : license)
```

Then **delete** the now-unused private methods `resolve_license`, `normalize_type` and `truthy?` (and the long comment block above `resolve_license`, which has moved to the new module). Leave `safe?` exactly as it is.

- [ ] **Step 7: Run the guard spec to prove behavior is unchanged**

Run: `bundle exec rspec spec/services/images/commercial_license_spec.rb spec/services/images/license_resolution_spec.rb`
Expected: PASS, 33 examples, 0 failures. The `commercial_license_spec` count must still be 25.

- [ ] **Step 8: Commit**

```bash
git add app/services/images/license_resolution.rb app/services/images/commercial_license.rb spec/services/images/license_resolution_spec.rb
git commit -m "refactor(images): extract LicenseResolution from CommercialLicense"
```

---

## Task 2: `Images::RedistributionLicense`

The export gate. Answers a different question from `CommercialLicense` — see the header comment in the code below, which is load-bearing documentation.

**Two traps this task must avoid, both of which are the reason it exists:**

1. **A `nil` `source_type` is not disqualifying.** User uploads were historically created with no source type. Treating `nil` as untrusted (as `CommercialLicense` correctly does *for selling*) would exclude a user's own photos from their own export.
2. **A stamped `user_id` is not authorship.** `Board.from_obf` creates `ObfImport` docs with `user_id: current_user.id`. A naive "the user owns it" check would therefore re-export imported third-party symbols as though the user had authored them. Ownership must additionally require a **user-authored source type**.

**Files:**
- Create: `app/services/images/redistribution_license.rb`
- Test: `spec/services/images/redistribution_license_spec.rb`

**Interfaces:**
- Consumes: `Images::LicenseResolution.resolve/1`, `Images::LicenseResolution.normalize_type/1` (Task 1)
- Produces: `Images::RedistributionLicense.for(doc, exporting_user:)` → `Result` responding to `bundlable?`, `attribution_required?`, `owned_by_user?`, `type` (`String` or `nil`), `reason` (`String` or `nil`)

- [ ] **Step 1: Write the failing test**

Create `spec/services/images/redistribution_license_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Images::RedistributionLicense do
  let(:user)  { create(:user) }
  let(:other) { create(:user) }

  def result_for(doc, exporting_user: user)
    described_class.for(doc, exporting_user: exporting_user)
  end

  # THE case this service exists for. User uploads were historically created
  # with no source_type; a "nil is untrusted" rule would drop a user's own
  # photos from their own export.
  describe "a user's own uploads" do
    it "bundles a legacy upload with a nil source_type" do
      doc = Doc.new(user_id: user.id, source_type: nil)
      r = result_for(doc)
      expect(r.bundlable?).to be true
      expect(r.owned_by_user?).to be true
    end

    it "bundles an upload stamped with the User source type" do
      doc = Doc.new(user_id: user.id, source_type: Doc::SOURCE_TYPE_USER)
      expect(result_for(doc).bundlable?).to be true
    end

    it "bundles when the parent Image is the user's even if the doc has no user_id" do
      image = create(:image, user: user)
      doc = Doc.new(documentable: image, source_type: nil)
      expect(result_for(doc).bundlable?).to be true
    end

    it "does not bundle another user's upload" do
      doc = Doc.new(user_id: other.id, source_type: Doc::SOURCE_TYPE_USER)
      r = result_for(doc)
      expect(r.bundlable?).to be false
      expect(r.owned_by_user?).to be false
    end
  end

  # Board.from_obf stamps ObfImport docs with the importing user's id. A
  # user_id match must NOT be read as authorship, or imported proprietary
  # symbols would be re-exported as the user's own work.
  describe "imported content stamped with the importing user's id" do
    it "does not treat an ObfImport doc as user-authored" do
      doc = Doc.new(user_id: user.id, source_type: "ObfImport", license: nil)
      r = result_for(doc)
      expect(r.bundlable?).to be false
      expect(r.owned_by_user?).to be false
    end

    it "still bundles an ObfImport doc that declares a redistributable license" do
      doc = Doc.new(user_id: user.id, source_type: "ObfImport", license: { "type" => "CC BY" })
      expect(result_for(doc).bundlable?).to be true
    end
  end

  describe "generated and library content" do
    it "bundles AI-generated docs" do
      expect(result_for(Doc.new(source_type: "OpenAI")).bundlable?).to be true
    end

    it "bundles SpeakAnyWay-owned uploads" do
      admin = User.find_by(id: User::DEFAULT_ADMIN_ID) || create(:admin_user, id: User::DEFAULT_ADMIN_ID)
      image = create(:image, user: admin)
      doc = Doc.new(documentable: image, source_type: nil)
      r = result_for(doc)
      expect(r.bundlable?).to be true
      expect(r.owned_by_user?).to be false
    end

    it "never bundles a protected symbol, even on the user's own image" do
      OpenSymbol.create!(search_string: "cup", license: "CC BY", protected_symbol: "true")
      image = create(:image, user: user)
      doc = Doc.new(documentable: image, user_id: user.id, source_type: "OpenSymbol", raw: "cup")
      r = result_for(doc)
      expect(r.bundlable?).to be false
      expect(r.reason).to match(/proprietary/i)
    end

    it "never bundles scraped web images" do
      doc = Doc.new(source_type: "GoogleSearch")
      expect(result_for(doc).bundlable?).to be false
    end
  end

  # The other reason this is not CommercialLicense: NC forbids commercial use
  # and ND forbids derivatives; neither forbids redistribution.
  describe "license families" do
    {
      "public domain"    => false,
      "CC0"              => false,
      "CC0 1.0"          => false,
      "CC BY"            => true,
      "CC BY 4.0"        => true,
      "CC BY-SA 3.0"     => true,
      "CC BY-NC"         => true,
      "CC BY-ND"         => true,
      "CC BY-NC-SA 4.0"  => true,
    }.each do |type, attribution|
      it "bundles #{type.inspect}" do
        doc = Doc.new(source_type: "ObfImport", license: { "type" => type })
        r = result_for(doc)
        expect(r.bundlable?).to be true
        expect(r.attribution_required?).to be attribution
      end
    end

    it "does not bundle an unrecognized license" do
      doc = Doc.new(source_type: "ObfImport", license: { "type" => "All Rights Reserved" })
      r = result_for(doc)
      expect(r.bundlable?).to be false
      expect(r.reason).to be_present
    end

    it "does not bundle when there is no license at all" do
      expect(result_for(Doc.new(source_type: "ObfImport")).bundlable?).to be false
    end
  end

  describe "no exporting user" do
    it "fails closed rather than raising" do
      doc = Doc.new(user_id: user.id, source_type: nil)
      expect(result_for(doc, exporting_user: nil).bundlable?).to be false
    end
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/services/images/redistribution_license_spec.rb`
Expected: FAIL — `uninitialized constant Images::RedistributionLicense`

- [ ] **Step 3: Write the implementation**

Create `app/services/images/redistribution_license.rb`:

```ruby
# app/services/images/redistribution_license.rb
#
# May this doc's bytes be bundled into a user's export package?
#
# NOT the same question as Images::CommercialLicense, which asks whether
# SpeakAnyWay may SELL a product containing the image. Two deliberate
# differences:
#
#   * NC and ND licenses are fine here. NC forbids commercial use and ND
#     forbids derivatives; neither forbids redistribution. Excluding them
#     would drop perfectly exportable images from a personal export.
#   * A blank source_type is NOT disqualifying on its own. User uploads were
#     historically created without one (see Doc::SOURCE_TYPE_USER), so a
#     "nil is untrusted" rule would exclude a user's own photos from their own
#     export — the exact opposite of this feature's purpose.
#
# Ownership is checked BEFORE license: a user's own content is theirs and its
# license is not ours to evaluate. License rules gate only third-party content.
#
# The predicate FAILS CLOSED — anything unrecognized is not bundlable.
module Images
  module RedistributionLicense
    # License families that permit redistribution. Matched after the -sa/-nc/-nd
    # obligation suffixes are stripped, so "cc by-nc-sa 4.0" lands on "cc by".
    REDISTRIBUTABLE_FAMILIES = ["public domain", "cc0", "cc by"].freeze

    # We generated it; it's ours.
    OWNED_SOURCE_TYPE = "OpenAI".freeze

    # Scraped from the web: not the user's content, and carrying no license.
    UNTRUSTED_SOURCE_TYPES = ["GoogleSearch"].freeze

    # Source types that indicate a person uploaded the file through a
    # user-facing endpoint. nil/"" are here because uploads predating
    # Doc::SOURCE_TYPE_USER carry no source type.
    #
    # This list is what stops a stamped user_id from being mistaken for
    # authorship: Board.from_obf creates "ObfImport" docs with
    # `user_id: current_user.id`, so without this restriction an import of
    # someone else's proprietary symbols would re-export as the user's own.
    USER_AUTHORED_SOURCE_TYPES = [nil, "", Doc::SOURCE_TYPE_USER].freeze

    Result = Struct.new(:bundlable, :type, :attribution_required, :owned_by_user, :reason) do
      def bundlable? = !!bundlable

      def attribution_required? = !!attribution_required

      def owned_by_user? = !!owned_by_user
    end

    class << self
      def for(doc, exporting_user:)
        license = LicenseResolution.resolve(doc)

        if license == :protected
          return Result.new(false, nil, false, false, "proprietary symbol set")
        end

        if user_authored?(doc, exporting_user)
          return Result.new(true, nil, false, true, nil)
        end

        if doc.source_type == OWNED_SOURCE_TYPE || speakanyway_authored?(doc)
          return Result.new(true, nil, false, false, nil)
        end

        if UNTRUSTED_SOURCE_TYPES.include?(doc.source_type)
          return Result.new(false, nil, false, false, "web-sourced image with no license on record")
        end

        type = LicenseResolution.normalize_type(license.is_a?(Hash) ? license["type"] : license)

        if redistributable?(type)
          return Result.new(true, type, type.start_with?("cc by"), false, nil)
        end

        Result.new(false, type.presence, false, false, "no redistributable license on record")
      end

      private

      def user_authored?(doc, exporting_user)
        return false if exporting_user.nil?

        owned_by?(doc, exporting_user.id)
      end

      def speakanyway_authored?(doc)
        owned_by?(doc, User::DEFAULT_ADMIN_ID)
      end

      # An upload counts as owned only when the source type says a person
      # uploaded it AND the owner matches. Checking the parent Image as well as
      # the doc covers uploads created before the doc carried a user_id.
      def owned_by?(doc, owner_id)
        return false unless USER_AUTHORED_SOURCE_TYPES.include?(doc.source_type)
        return true if doc.user_id.present? && doc.user_id == owner_id

        parent = doc.documentable
        parent.is_a?(Image) && parent.user_id.present? && parent.user_id == owner_id
      end

      # Strip the obligation suffixes before matching so every CC BY variant
      # collapses onto the "cc by" family. "cc by-nc-sa 4.0" -> "cc by 4.0".
      def redistributable?(type)
        return false if type.blank?

        base = type.gsub(/-(sa|nc|nd)\b/, "").strip
        REDISTRIBUTABLE_FAMILIES.any? { |allowed| base == allowed || base.start_with?("#{allowed} ") }
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/services/images/redistribution_license_spec.rb`
Expected: PASS, 22 examples, 0 failures

- [ ] **Step 5: Re-run the guard spec**

Run: `bundle exec rspec spec/services/images/`
Expected: PASS, all green — `commercial_license_spec` still 25 examples.

- [ ] **Step 6: Commit**

```bash
git add app/services/images/redistribution_license.rb spec/services/images/redistribution_license_spec.rb
git commit -m "feat(images): add RedistributionLicense export gate"
```

---

## Task 3: Fix `format_grid`

Three defects, all in `BoardsHelper#format_grid`, whose only caller is `to_obf`:

1. It writes grid `order` cell ids as **integers** (`cell["i"].to_i`) while buttons emit `id` as strings. Our own importer coerces both, so it round-trips with itself, but a spec-strict third-party importer will fail to match them.
2. It reads `large_screen_columns` raw, bypassing `get_number_of_columns`'s fallback, so a board with the column count unset produces a zero-width grid.
3. It has no handling for a blank or invalid `layout`.

**Files:**
- Modify: `app/helpers/boards_helper.rb` (the `format_grid` method)
- Test: `spec/helpers/boards_helper_format_grid_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces: `Board#format_grid` → `{ "rows" => Integer, "columns" => Integer, "order" => Array<Array<String, nil>> }`

- [ ] **Step 1: Write the failing test**

Create `spec/helpers/boards_helper_format_grid_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "BoardsHelper#format_grid" do
  let(:user) { create(:user) }

  def board_with_tiles(count, columns: 3)
    board = create(:board, user: user, large_screen_columns: columns)
    count.times do |i|
      image = create(:image, label: "tile_#{i}", user: user)
      board.board_images.create!(image_id: image.id, position: i, skip_create_voice_audio: true)
    end
    board.reload
  end

  it "emits order cell ids as strings so they match button ids" do
    board = board_with_tiles(3)
    board.set_layouts_for_screen_sizes

    grid = board.format_grid
    ids = grid["order"].flatten.compact

    expect(ids).to all(be_a(String))
    button_ids = board.board_images.map { |bi| bi.to_obf_button_format[:id] }
    expect(ids).to match_array(button_ids)
  end

  it "falls back to position ordering when the layout is blank" do
    board = board_with_tiles(4, columns: 2)
    board.update_column(:layout, {})

    grid = board.format_grid

    expect(grid["columns"]).to eq(2)
    expect(grid["rows"]).to eq(2)
    expect(grid["order"].flatten.compact.size).to eq(4)
  end

  it "uses the derived column count when large_screen_columns is unset" do
    board = board_with_tiles(2)
    board.update_column(:large_screen_columns, 0)

    expect(board.format_grid["columns"]).to be > 0
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/helpers/boards_helper_format_grid_spec.rb`
Expected: FAIL — the first example fails because ids are `Integer`, and the blank-layout example raises or returns an empty grid.

- [ ] **Step 3: Replace `format_grid`**

In `app/helpers/boards_helper.rb`, replace the whole `format_grid` method with:

```ruby
  # Builds the OBF `grid` block. Cell ids are STRINGS so they match the
  # `id` emitted by BoardImage#to_obf_button_format — the OBF spec matches
  # grid order against button ids by value, and a third-party importer will
  # not coerce integers for us.
  #
  # Falls back to position ordering when the stored layout is missing or
  # unusable, so an unlaid-out board still exports a valid grid.
  def format_grid
    columns = get_number_of_columns("lg")
    columns = 1 if columns.to_i < 1
    cells = print_grid_layout_for_screen_size("lg")

    return position_ordered_grid(columns) if cells.blank?

    rows = cells.filter_map { |cell| cell["y"].to_i + [cell["h"].to_i, 1].max }.max.to_i
    return position_ordered_grid(columns) if rows < 1

    order = Array.new(rows) { Array.new(columns, nil) }
    cells.each do |cell|
      x = cell["x"].to_i
      y = cell["y"].to_i
      next if x.negative? || y.negative? || x >= columns || y >= rows

      order[y][x] = cell["i"].to_s
    end

    { "rows" => rows, "columns" => columns, "order" => order }
  end

  # Last-resort grid: fill left-to-right, top-to-bottom in tile position order.
  def position_ordered_grid(columns)
    ids = board_images.sort_by { |bi| bi.position.to_i }.map { |bi| bi.id.to_s }
    rows = [(ids.size.to_f / columns).ceil, 1].max

    order = Array.new(rows) { Array.new(columns, nil) }
    ids.each_with_index { |id, index| order[index / columns][index % columns] = id }

    { "rows" => rows, "columns" => columns, "order" => order }
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/helpers/boards_helper_format_grid_spec.rb`
Expected: PASS, 3 examples, 0 failures

- [ ] **Step 5: Verify the existing export request spec still passes**

Run: `bundle exec rspec spec/requests/api/boards/import_export_spec.rb`
Expected: PASS, 9 examples, 0 failures

- [ ] **Step 6: Commit**

```bash
git add app/helpers/boards_helper.rb spec/helpers/boards_helper_format_grid_spec.rb
git commit -m "fix(obf): emit grid order ids as strings and handle blank layouts"
```

---

## Task 4: Asset modes on `BoardImage`

`to_obf_image_format` currently emits only a remote `url:`. The exporter needs three shapes: `:url` (as today), `:inline` (base64 `data:`, for a standalone `.obf`), and `:package` (a zip-relative `path:`, for `.obz`). `to_obf_button_format` also needs `load_board.path` so other apps can resolve links by path.

**Files:**
- Modify: `app/models/board_image.rb` (`to_obf_image_format`, `to_obf_button_format`)
- Test: `spec/models/board_image_obf_format_spec.rb`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `BoardImage#to_obf_image_format(viewing_user = nil, mode: :url, path: nil, data: nil)` → `Hash`
  - `BoardImage#to_obf_button_format(load_board_path: nil)` → `Hash`
  - `BoardImage#export_doc(viewing_user = nil)` → `Doc` or `nil` — the doc whose bytes back this tile

- [ ] **Step 1: Write the failing test**

Create `spec/models/board_image_obf_format_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe BoardImage, "OBF formatting" do
  let(:user)  { create(:user) }
  let(:board) { create(:board, user: user) }
  let(:image) { create(:image, label: "cup", user: user) }
  let!(:board_image) do
    board.board_images.create!(image_id: image.id, position: 0, skip_create_voice_audio: true)
  end

  before do
    allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/cup.png")
    allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
  end

  describe "#to_obf_image_format" do
    it "emits a url reference by default" do
      result = board_image.to_obf_image_format(user)
      expect(result[:url]).to eq("https://example.test/cup.png")
      expect(result).not_to have_key(:path)
      expect(result).not_to have_key(:data)
    end

    it "emits a zip path and no url in package mode" do
      result = board_image.to_obf_image_format(user, mode: :package, path: "images/9.png")
      expect(result[:path]).to eq("images/9.png")
      expect(result).not_to have_key(:url)
    end

    it "emits inline data and no url in inline mode" do
      result = board_image.to_obf_image_format(user, mode: :inline, data: "QUJD")
      expect(result[:data]).to eq("QUJD")
      expect(result).not_to have_key(:url)
    end

    it "falls back to a url when package mode has no path" do
      result = board_image.to_obf_image_format(user, mode: :package, path: nil)
      expect(result[:url]).to eq("https://example.test/cup.png")
    end
  end

  describe "#to_obf_button_format" do
    let(:target) { create(:board, user: user, name: "Food") }

    before { board_image.update!(predictive_board_id: target.id) }

    it "includes load_board path alongside id when given one" do
      result = board_image.to_obf_button_format(load_board_path: "boards/#{target.id}.obf")
      expect(result[:load_board][:id]).to eq(target.id.to_s)
      expect(result[:load_board][:path]).to eq("boards/#{target.id}.obf")
    end

    it "omits load_board path when none is given" do
      result = board_image.to_obf_button_format
      expect(result[:load_board]).not_to have_key(:path)
    end
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/models/board_image_obf_format_spec.rb`
Expected: FAIL — `to_obf_image_format` takes 1 argument, `unknown keyword: :mode`

- [ ] **Step 3: Update the two methods**

In `app/models/board_image.rb`, replace `to_obf_image_format` with:

```ruby
  # `mode` selects how the bytes are referenced:
  #   :url     — remote URL (default; what a bare .obf download used to do)
  #   :inline  — base64 in `data`, for a standalone .obf with no package
  #   :package — zip-relative `path`, for .obz
  # Falls back to :url when the caller could not supply a path/data, so a
  # single unreadable asset degrades instead of breaking the export.
  def to_obf_image_format(viewing_user = nil, mode: :url, path: nil, data: nil)
    viewing_user ||= user
    base = {
      id: id.to_s,
      content_type: image.content_type,
      ext_saw_label: label,
      ext_saw_voice: voice,
      ext_board_type: board.board_type,
    }

    case mode
    when :package
      return base.merge(path: path).compact if path.present?
    when :inline
      return base.merge(data: data).compact if data.present?
    end

    base.merge(url: tile_image_url(viewing_user)).compact
  end

  # The doc whose bytes back this tile. Licensing and packaging both key on
  # this, so they must agree on which doc was used.
  def export_doc(viewing_user = nil)
    viewing_user ||= user
    image&.display_doc(viewing_user)
  end
```

Then in `to_obf_button_format`, change the signature and the `load_board` block. Replace:

```ruby
  def to_obf_button_format
```

with:

```ruby
  def to_obf_button_format(load_board_path: nil)
```

and replace:

```ruby
        btn[:load_board] = {
          id: (target.obf_id.presence || target.id.to_s),
          name: target.name,
        }
```

with:

```ruby
        btn[:load_board] = {
          id: (target.obf_id.presence || target.id.to_s),
          name: target.name,
        }
        # Per the OBF spec load_board may resolve by id or by path. Most apps
        # use path inside a .obz, so emit both when packaging.
        btn[:load_board][:path] = load_board_path if load_board_path.present?
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/models/board_image_obf_format_spec.rb`
Expected: PASS, 6 examples, 0 failures

- [ ] **Step 5: Check nothing else broke**

Run: `bundle exec rspec spec/models/board_image_spec.rb spec/requests/api/boards/import_export_spec.rb`
Expected: PASS, 0 failures

- [ ] **Step 6: Commit**

```bash
git add app/models/board_image.rb spec/models/board_image_obf_format_spec.rb
git commit -m "feat(obf): add asset modes and load_board path to BoardImage OBF format"
```

---

## Task 5: `Boards::ObfExporter` and the derived license

Replaces `BoardsHelper#to_obf`. Produces the OBF hash for one board plus the list of assets a packager must write, and the list it refused to bundle.

`Board#license` currently hard-codes `CC BY-SA 4.0` for every board. It becomes derived, and it must be derived **per exporting user**, because ownership is what distinguishes `private` from an open license. Note that bundling and the declared license are *independent*: a board of the user's own photos bundles every asset **and** declares `private`, because SpeakAnyWay has no standing to license someone's family photos under CC BY-SA.

**Files:**
- Create: `app/services/boards/obf_exporter.rb`
- Modify: `app/helpers/boards_helper.rb` (delete `to_obf`)
- Test: `spec/services/boards/obf_exporter_spec.rb`

**Interfaces:**
- Consumes: `Images::RedistributionLicense.for/2` (Task 2); `Board#format_grid` (Task 3); `BoardImage#to_obf_image_format`, `#to_obf_button_format`, `#export_doc` (Task 4)
- Produces:
  - `Boards::ObfExporter.new(board, exporting_user:, asset_mode: :url, board_paths: {}).call` → `Result`
  - `Result` is a `Struct` with members `obf` (`Hash`), `assets` (`Array<Asset>`), `skipped_assets` (`Array<Hash>`)
  - `Asset` is a `Struct` with members `kind` (`:image`), `id` (`String`), `path` (`String`), `doc` (`Doc`)
  - `board_paths` maps `board_id (Integer) => zip path (String)`, used for `load_board.path`

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/obf_exporter_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb`
Expected: FAIL — `uninitialized constant Boards::ObfExporter`

- [ ] **Step 3: Write the implementation**

Create `app/services/boards/obf_exporter.rb`:

```ruby
require "base64"

module Boards
  # One board -> one OBF document, plus the assets a packager must write and
  # the ones we refused to bundle.
  #
  # Bundling and the declared license are INDEPENDENT decisions:
  #   * bundling  — per asset, via Images::RedistributionLicense
  #   * license   — per board, derived from what is actually inside
  # A board of a user's own photos bundles every asset AND declares "private",
  # because SpeakAnyWay has no standing to license a user's family photos
  # under an open license on their behalf.
  class ObfExporter
    FORMAT = "open-board-0.1".freeze
    OPEN_LICENSE = { "type" => "CC BY-SA 4.0",
                     "url" => "https://creativecommons.org/licenses/by-sa/4.0/" }.freeze
    PRIVATE_LICENSE = { "type" => "private" }.freeze

    EXTENSIONS_BY_CONTENT_TYPE = {
      "image/png" => "png",
      "image/jpeg" => "jpg",
      "image/gif" => "gif",
      "image/svg+xml" => "svg",
      "image/webp" => "webp",
    }.freeze

    Asset  = Struct.new(:kind, :id, :path, :doc)
    Result = Struct.new(:obf, :assets, :skipped_assets)

    def initialize(board, exporting_user:, asset_mode: :url, board_paths: {})
      @board = board
      @exporting_user = exporting_user
      @asset_mode = asset_mode
      @board_paths = board_paths || {}
      @assets = []
      @skipped_assets = []
      @owned_by_user = false
      @license_types = []
    end

    def call
      tiles = board.board_images.to_a
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

      Result.new(obf, assets, skipped_assets)
    end

    private

    attr_reader :board, :exporting_user, :asset_mode, :board_paths, :assets, :skipped_assets

    def button_entry(tile)
      tile.to_obf_button_format(load_board_path: board_paths[tile.predictive_board_id])
    end

    def image_entry(tile)
      return tile.to_obf_image_format(exporting_user) if asset_mode == :url

      doc = tile.export_doc(exporting_user)
      verdict = doc && Images::RedistributionLicense.for(doc, exporting_user: exporting_user)

      unless verdict&.bundlable?
        skipped_assets << { board_image_id: tile.id, label: tile.label,
                            reason: verdict&.reason || "no image on record" }
        return tile.to_obf_image_format(exporting_user)
      end

      record_license(verdict)
      attach_asset(tile, doc)
    end

    # Reads the bytes for a bundlable asset. A blob we cannot read degrades to a
    # url reference and is recorded — one bad image must never cost the user
    # the whole export.
    def attach_asset(tile, doc)
      return tile.to_obf_image_format(exporting_user) unless doc.image.attached?

      path = "images/#{doc.id}.#{asset_extension(doc)}"

      if asset_mode == :inline
        data = Base64.strict_encode64(doc.image.download)
        return tile.to_obf_image_format(exporting_user, mode: :inline, data: data)
      end

      assets << Asset.new(:image, doc.id.to_s, path, doc)
      tile.to_obf_image_format(exporting_user, mode: :package, path: path)
    rescue StandardError => e
      Rails.logger.warn "[ObfExporter] asset unreadable for doc #{doc.id}: #{e.class}: #{e.message}"
      skipped_assets << { board_image_id: tile.id, label: tile.label, reason: "image could not be read" }
      tile.to_obf_image_format(exporting_user)
    end

    # NOT Doc#extension: that reads `original_image_url`, which is nil for
    # user uploads (only the download-from-URL paths set it) and keeps query
    # strings when present. Read the blob instead, which is always right for an
    # attached asset.
    def asset_extension(doc)
      ext = doc.image.filename.extension.presence
      return ext.downcase if ext.present?

      EXTENSIONS_BY_CONTENT_TYPE.fetch(doc.image.content_type, "png")
    end

    def record_license(verdict)
      @owned_by_user ||= verdict.owned_by_user?
      @license_types << verdict.type if verdict.type.present?
    end

    # Any content the user owns makes the board theirs, not ours to license.
    # Otherwise fall back to the open license only when nothing carried a more
    # restrictive one.
    def derived_license
      return PRIVATE_LICENSE if @owned_by_user
      return OPEN_LICENSE if @license_types.empty?

      { "type" => @license_types.uniq.sort.last }
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb`
Expected: PASS, 5 examples, 0 failures

- [ ] **Step 5: Delete the superseded helper**

In `app/helpers/boards_helper.rb`, delete the entire `to_obf` method (the first method in the module) and the now-unneeded `require "obf"` at the top of the file. Leave `format_grid`, `position_ordered_grid`, `description_html`, `get_number_of_columns` and everything below untouched.

- [ ] **Step 6: Delete the hard-coded `Board#license`**

`to_obf` was its only caller, so it is now dead code that asserts a licence every board does not have. In `app/models/board.rb` (around line 579) delete:

```ruby
  def license
    { "name" => "CC BY-SA 4.0", "url" => "https://creativecommons.org/licenses/by-sa/4.0/" }
  end
```

There is no `license` column on `boards`, so nothing else resolves this name.

- [ ] **Step 7: Confirm nothing else called either one**

Run: `grep -rn "to_obf\b" app lib spec --include="*.rb" | grep -v "to_obf_image_format\|to_obf_sound_format\|to_obf_button_format\|obf_exporter"`
Expected: exactly one hit — `app/controllers/api/boards_controller.rb`, which Task 6 rewrites.

Run: `grep -rn "board\.license\|@board\.license" app lib spec --include="*.rb"`
Expected: no output.

- [ ] **Step 8: Re-run the suite touched so far**

Run: `bundle exec rspec spec/services/boards/obf_exporter_spec.rb spec/models/board_spec.rb`
Expected: PASS, 0 failures

- [ ] **Step 9: Commit**

```bash
git add app/services/boards/obf_exporter.rb app/helpers/boards_helper.rb app/models/board.rb spec/services/boards/obf_exporter_spec.rb
git commit -m "feat(obf): add ObfExporter with per-asset bundling and derived license"
```

---

## Task 6: Fix and rewire `download_obf`

Three problems in the existing action:

```ruby
def download_obf
  set_board
  obf_board = @board.to_obf(current_user)
  send_data obf_board.to_json, filename: "board.obf", ...
end
```

1. **No authorization.** `set_board` only *finds* the board. Any authenticated user can download any board's OBF, including other users' private boards. `show` guards this with `@board.viewable_by?(current_user)` and returns a generic 404 so it doesn't confirm the board exists — this action must do the same. Latent today because nothing calls it; a real IDOR the moment the UI ships.
2. Filename is the literal `"board.obf"` for every board.
3. It calls the deleted `to_obf`.

**Files:**
- Modify: `app/controllers/api/boards_controller.rb` (`download_obf`)
- Test: `spec/requests/api/boards/import_export_spec.rb` (extend the existing `download_obf` describe block)

**Interfaces:**
- Consumes: `Boards::ObfExporter` (Task 5)
- Produces: `GET /api/boards/:id/download_obf` → `application/json`, `Content-Disposition: attachment; filename="<board-name>.obf"`

- [ ] **Step 1: Write the failing tests**

In `spec/requests/api/boards/import_export_spec.rb`, inside the existing `describe "GET /api/boards/:id/download_obf"` block, add:

```ruby
    it "names the file after the board" do
      get "/api/boards/#{board.id}/download_obf", headers: auth_headers(user)
      expect(response.headers["Content-Disposition"]).to include('filename="exportable-board.obf"')
    end

    it "inlines image data rather than only linking to it" do
      get "/api/boards/#{board.id}/download_obf", headers: auth_headers(user)
      image = JSON.parse(response.body)["images"].first
      expect(image.key?("data") || image.key?("url")).to be true
    end

    context "when the board belongs to someone else and is not published" do
      let!(:stranger) { create(:user) }

      it "returns 404 without confirming the board exists" do
        get "/api/boards/#{board.id}/download_obf", headers: auth_headers(stranger)
        expect(response).to have_http_status(:not_found)
      end
    end
```

- [ ] **Step 2: Run them to make sure they fail**

Run: `bundle exec rspec spec/requests/api/boards/import_export_spec.rb`
Expected: FAIL — the filename example fails on `"board.obf"`, and the stranger example returns 200 instead of 404.

- [ ] **Step 3: Rewrite the action**

In `app/controllers/api/boards_controller.rb`, replace `download_obf` with:

```ruby
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
  end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `bundle exec rspec spec/requests/api/boards/import_export_spec.rb`
Expected: PASS, 12 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add app/controllers/api/boards_controller.rb spec/requests/api/boards/import_export_spec.rb
git commit -m "fix(obf): authorize download_obf and name the file after the board"
```

---

## Task 7: `BoardExport` model and migration

The record a `.obz` export writes to, and the client polls. Modelled on `BoardScreenshotImport`.

Note the column is `file_format`, not `format` — an ActiveRecord attribute named `format` shadows `Kernel#format` and confuses controller/view code.

**Files:**
- Create: `db/migrate/20260730120000_create_board_exports.rb`
- Create: `app/models/board_export.rb`
- Test: `spec/models/board_export_spec.rb`

**Interfaces:**
- Consumes: nothing.
- Produces: `BoardExport` with `status` (`queued`/`processing`/`completed`/`failed`), `file_format`, `error_message`, `settings` (jsonb), `belongs_to :user`, `belongs_to :exportable` (polymorphic), `has_one_attached :file`; `#api_view` → `Hash`

- [ ] **Step 1: Write the migration**

Create `db/migrate/20260730120000_create_board_exports.rb`:

```ruby
class CreateBoardExports < ActiveRecord::Migration[8.0]
  def change
    create_table :board_exports do |t|
      t.references :user, null: false, foreign_key: true
      t.references :exportable, polymorphic: true, null: false
      t.string :status, null: false, default: "queued"
      t.string :file_format, null: false, default: "obz"
      t.text :error_message
      t.jsonb :settings, null: false, default: {}

      t.timestamps
    end

    add_index :board_exports, [:user_id, :created_at]
  end
end
```

- [ ] **Step 2: Run the migration**

Run: `bin/rails db:migrate`
Expected: `== CreateBoardExports: migrated` and `db/schema.rb` updated.

- [ ] **Step 3: Write the failing test**

Create `spec/models/board_export_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe BoardExport do
  let(:user)  { create(:user) }
  let(:board) { create(:board, user: user) }

  it "defaults to queued" do
    expect(described_class.create!(user: user, exportable: board).status).to eq("queued")
  end

  it "rejects an unknown status" do
    record = described_class.new(user: user, exportable: board, status: "nonsense")
    expect(record).not_to be_valid
  end

  it "reports no download url until the file is attached" do
    record = described_class.create!(user: user, exportable: board, status: "completed")
    expect(record.api_view[:download_url]).to be_nil
  end

  it "exposes status and error in the api view" do
    record = described_class.create!(user: user, exportable: board,
                                     status: "failed", error_message: "boom")
    view = record.api_view
    expect(view[:status]).to eq("failed")
    expect(view[:error_message]).to eq("boom")
  end
end
```

- [ ] **Step 4: Run it to make sure it fails**

Run: `bundle exec rspec spec/models/board_export_spec.rb`
Expected: FAIL — `uninitialized constant BoardExport`

- [ ] **Step 5: Write the model**

Create `app/models/board_export.rb`:

```ruby
class BoardExport < ApplicationRecord
  STATUSES = %w[queued processing completed failed].freeze

  belongs_to :user
  belongs_to :exportable, polymorphic: true
  has_one_attached :file

  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def completed? = status == "completed"

  def mark_processing! = update!(status: "processing")

  def mark_failed!(message)
    update!(status: "failed", error_message: message)
  end

  def api_view
    {
      id: id,
      status: status,
      file_format: file_format,
      error_message: error_message,
      download_url: (Rails.application.routes.url_helpers.download_api_board_export_path(self) if completed? && file.attached?),
      summary: settings["exported_to_obf"],
      created_at: created_at,
    }
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `bundle exec rspec spec/models/board_export_spec.rb`
Expected: FAIL on `download_api_board_export_path` — the route does not exist yet. That is expected; Task 9 adds it. Temporarily confirm the other three examples pass:

Run: `bundle exec rspec spec/models/board_export_spec.rb -e "defaults to queued" -e "rejects an unknown status" -e "exposes status"`
Expected: PASS, 3 examples, 0 failures

- [ ] **Step 7: Commit**

```bash
git add db/migrate/20260730120000_create_board_exports.rb db/schema.rb app/models/board_export.rb spec/models/board_export_spec.rb
git commit -m "feat(export): add BoardExport record for async package exports"
```

---

## Task 8: `Boards::ExportScope`

Resolves an export request into the ordered boards to include, the root, and the boards deliberately left out.

Two caps are needed, not one. `Boards::PredictiveLinkSet.collect` is bounded by `max_depth` **only** — it has no board-count limit (the `MAX_BOARDS = 500` constant belongs to `SetGraphBuilder`, a different service). A wide, shallow graph would otherwise produce an unbounded package.

**Files:**
- Create: `app/services/boards/export_scope.rb`
- Test: `spec/services/boards/export_scope_spec.rb`

**Interfaces:**
- Consumes: `Boards::PredictiveLinkSet.collect(root, max_depth:, exclude:)`; `Board#viewable_by?`
- Produces:
  - `Boards::ExportScope.for_board(board, exporting_user:)` → `Result`
  - `Boards::ExportScope.for_group(board_group, exporting_user:)` → `Result`
  - `Result` is a `Struct` with members `boards` (`Array<Board>`, root first), `root` (`Board`), `skipped_boards` (`Array<Hash>` with keys `:board_id`, `:reason`)

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/export_scope_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Boards::ExportScope do
  let(:user)    { create(:user) }
  let(:stranger) { create(:user) }

  def link(from_board, to_board)
    image = create(:image, label: "go_#{to_board.id}", user: user)
    from_board.board_images.create!(image_id: image.id, position: from_board.board_images.count,
                                    predictive_board_id: to_board.id, skip_create_voice_audio: true)
  end

  describe ".for_board" do
    it "returns the root first, followed by linked boards" do
      root  = create(:board, user: user, name: "Root")
      child = create(:board, user: user, name: "Child")
      link(root, child)

      result = described_class.for_board(root.reload, exporting_user: user)

      expect(result.root).to eq(root)
      expect(result.boards.first).to eq(root)
      expect(result.boards).to include(child)
    end

    it "does not loop on a cycle" do
      a = create(:board, user: user, name: "A")
      b = create(:board, user: user, name: "B")
      link(a, b)
      link(b, a)

      result = described_class.for_board(a.reload, exporting_user: user)

      expect(result.boards.map(&:id).uniq.size).to eq(result.boards.size)
      expect(result.boards.size).to eq(2)
    end

    it "skips a linked board the user may not read" do
      root   = create(:board, user: user, name: "Root")
      hidden = create(:board, user: stranger, name: "Hidden", published: false)
      link(root, hidden)

      result = described_class.for_board(root.reload, exporting_user: user)

      expect(result.boards).not_to include(hidden)
      expect(result.skipped_boards.first[:board_id]).to eq(hidden.id)
    end

    it "caps the number of boards and records the overflow" do
      stub_const("Boards::ExportScope::MAX_BOARDS", 2)
      root = create(:board, user: user, name: "Root")
      3.times { |i| link(root, create(:board, user: user, name: "C#{i}")) }

      result = described_class.for_board(root.reload, exporting_user: user)

      expect(result.boards.size).to eq(2)
      expect(result.skipped_boards).not_to be_empty
    end
  end

  describe ".for_group" do
    it "returns the group's boards with the root board first" do
      group = create(:board_group, user: user)
      first = create(:board, user: user, name: "One")
      second = create(:board, user: user, name: "Two")
      group.add_board(first)
      group.add_board(second)
      group.update!(root_board_id: second.id)

      result = described_class.for_group(group.reload, exporting_user: user)

      expect(result.root).to eq(second)
      expect(result.boards.first).to eq(second)
      expect(result.boards.map(&:id)).to match_array([first.id, second.id])
    end
  end
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `bundle exec rspec spec/services/boards/export_scope_spec.rb`
Expected: FAIL — `uninitialized constant Boards::ExportScope`

- [ ] **Step 3: Write the implementation**

Create `app/services/boards/export_scope.rb`:

```ruby
module Boards
  # Resolves an export request into the boards to include, the root, and the
  # boards deliberately left out.
  #
  # Boards::PredictiveLinkSet.collect is bounded by max_depth ONLY — it has no
  # board-count limit (MAX_BOARDS on SetGraphBuilder is a different service).
  # A wide, shallow link graph would otherwise produce an unbounded package, so
  # this service imposes its own count cap on top of the depth cap.
  class ExportScope
    MAX_BOARDS = 200
    MAX_DEPTH = 6

    Result = Struct.new(:boards, :root, :skipped_boards)

    class << self
      # A board plus everything reachable through its predictive links.
      def for_board(board, exporting_user:)
        skipped = []

        collected = PredictiveLinkSet.collect(
          board,
          max_depth: MAX_DEPTH,
          exclude: ->(candidate) do
            next false if candidate.viewable_by?(exporting_user)

            skipped << { board_id: candidate.id, reason: "not readable by the exporting user" }
            true
          end,
        )

        capped, overflow = cap(collected)
        overflow.each { |b| skipped << { board_id: b.id, reason: "package board limit reached" } }

        Result.new(capped, board, skipped)
      end

      # An explicit Board Set. Membership is already curated, so there is no
      # link walking — only the read check and the count cap.
      def for_group(board_group, exporting_user:)
        skipped = []
        members = board_group.boards.to_a

        readable = members.select do |b|
          next true if b.viewable_by?(exporting_user)

          skipped << { board_id: b.id, reason: "not readable by the exporting user" }
          false
        end

        root = board_group.root_board if board_group.root_board_id.present?
        root = readable.first unless root && readable.any? { |b| b.id == root.id }

        ordered = readable.sort_by { |b| b.id == root&.id ? 0 : 1 }
        capped, overflow = cap(ordered)
        overflow.each { |b| skipped << { board_id: b.id, reason: "package board limit reached" } }

        Result.new(capped, root, skipped)
      end

      private

      def cap(boards)
        [boards.first(MAX_BOARDS), boards.drop(MAX_BOARDS)]
      end
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `bundle exec rspec spec/services/boards/export_scope_spec.rb`
Expected: PASS, 5 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add app/services/boards/export_scope.rb spec/services/boards/export_scope_spec.rb
git commit -m "feat(export): add ExportScope with read checks and a board-count cap"
```

---

## Task 9: `Boards::ObzPackager`

Writes the zip. The layout deliberately mirrors what `ObzImporter` reads — `manifest["root"]` and `manifest.dig("paths", "boards")` — so round-trip is structural rather than hopeful.

**Files:**
- Modify: `Gemfile` (promote `rubyzip` to an explicit dependency)
- Create: `app/services/boards/obz_packager.rb`
- Test: `spec/services/boards/obz_packager_spec.rb`

**Interfaces:**
- Consumes: `Boards::ExportScope::Result` (Task 8); `Boards::ObfExporter` (Task 5)
- Produces:
  - `Boards::ObzPackager.new(scope_result, exporting_user:).call` → `Result`
  - `Result` is a `Struct` with members `bytes` (`String`, binary), `summary` (`Hash`)
  - `summary` keys: `"bundled_assets"` (`Integer`), `"skipped_assets"` (`Array<Hash>`), `"skipped_boards"` (`Array<Hash>`), `"licenses"` (`Array<String>`)

- [ ] **Step 1: Promote rubyzip to an explicit dependency**

In `Gemfile`, directly below the `gem "obf", "~> 0.9.9"` line, add:

```ruby
# Explicit because ObzImporter/ObzPackager `require "zip"` directly. It has
# been present only as a transitive dependency, which is fragile.
gem "rubyzip", "~> 2.3"
```

Run: `bundle install`
Expected: `Bundle complete!`, and `Gemfile.lock` now lists `rubyzip` under DEPENDENCIES.

- [ ] **Step 2: Write the failing test**

Create `spec/services/boards/obz_packager_spec.rb`:

```ruby
require "rails_helper"
require "zip"

RSpec.describe Boards::ObzPackager do
  let(:user) { create(:user) }

  def entries_in(bytes)
    names = {}
    Zip::File.open_buffer(bytes) { |zip| zip.each { |e| names[e.name] = e.get_input_stream.read } }
    names
  end

  def board_with_tile(name)
    board = create(:board, user: user, name: name)
    image = create(:image, label: "tile", user: user)
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
```

- [ ] **Step 3: Run it to make sure it fails**

Run: `bundle exec rspec spec/services/boards/obz_packager_spec.rb`
Expected: FAIL — `uninitialized constant Boards::ObzPackager`

- [ ] **Step 4: Write the implementation**

Create `app/services/boards/obz_packager.rb`:

```ruby
require "zip"
require "json"
require "stringio"

module Boards
  # Writes a .obz package. The layout mirrors exactly what ObzImporter reads —
  # manifest["root"] plus manifest["paths"]["boards"] — so an exported package
  # re-imports cleanly. Changing the layout here without changing ObzImporter
  # breaks the round-trip spec, which is the point of that spec.
  class ObzPackager
    class TooLarge < StandardError; end

    FORMAT = "open-board-0.1".freeze

    # Belt to ExportScope::MAX_BOARDS' braces: a small number of boards can
    # still carry very large images. Fails with an explicit error rather than
    # letting the job die on memory or the upload time out.
    MAX_BYTES = 200 * 1024 * 1024

    Result = Struct.new(:bytes, :summary)

    def initialize(scope_result, exporting_user:)
      @scope = scope_result
      @exporting_user = exporting_user
    end

    def call
      board_paths = scope.boards.to_h { |board| [board.id, "boards/#{board.id}.obf"] }

      exports = scope.boards.map do |board|
        [board, ObfExporter.new(board, exporting_user: exporting_user,
                                       asset_mode: :package, board_paths: board_paths).call]
      end

      bytes = build_zip(exports, board_paths)
      raise TooLarge, "Package exceeds the #{MAX_BYTES / 1024 / 1024}MB limit" if bytes.bytesize > MAX_BYTES

      Result.new(bytes, summarize(exports))
    end

    private

    attr_reader :scope, :exporting_user

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
    # boards, and a zip must not contain the same entry twice.
    def write_assets(zip, exports)
      seen = {}

      exports.each do |_board, result|
        result.assets.each do |asset|
          next if seen.key?(asset.path)

          seen[asset.path] = asset.id
          zip.put_next_entry(asset.path)
          zip.write(asset.doc.image.download)
        end
      end

      seen
    end

    def manifest(exports, board_paths, written_assets)
      boards = exports.to_h { |board, _| [board.id.to_s, board_paths[board.id]] }
      images = written_assets.to_h { |path, id| [id, path] }

      {
        "format" => FORMAT,
        "root" => board_paths[scope.root&.id] || board_paths.values.first,
        "paths" => { "boards" => boards, "images" => images, "sounds" => {} },
      }
    end

    def summarize(exports)
      {
        "bundled_assets" => exports.sum { |_b, r| r.assets.size },
        "skipped_assets" => exports.flat_map { |_b, r| r.skipped_assets },
        "skipped_boards" => scope.skipped_boards,
        "licenses" => exports.map { |_b, r| r.obf["license"]["type"] }.uniq,
        "exported_by_user_id" => exporting_user&.id,
        "exported_at" => Time.current.iso8601,
      }
    end

    def readme_text(exports)
      skipped_assets = exports.flat_map { |_b, r| r.skipped_assets }
      return nil if skipped_assets.empty? && scope.skipped_boards.empty?

      lines = ["This package was exported from SpeakAnyWay (https://speakanyway.com).", ""]

      if skipped_assets.any?
        lines << "Some images are referenced by link rather than included as files:"
        skipped_assets.each { |a| lines << "  - #{a[:label]}: #{a[:reason]}" }
        lines << ""
      end

      if scope.skipped_boards.any?
        lines << "Some linked boards were not included:"
        scope.skipped_boards.each { |b| lines << "  - board #{b[:board_id]}: #{b[:reason]}" }
        lines << ""
      end

      lines.join("\n")
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `bundle exec rspec spec/services/boards/obz_packager_spec.rb`
Expected: PASS, 3 examples, 0 failures

- [ ] **Step 6: Commit**

```bash
git add Gemfile Gemfile.lock app/services/boards/obz_packager.rb spec/services/boards/obz_packager_spec.rb
git commit -m "feat(export): add ObzPackager writing importer-compatible packages"
```

---

## Task 10: Job, endpoints and routes

**Files:**
- Create: `app/sidekiq/export_board_package_job.rb`
- Create: `app/controllers/api/board_exports_controller.rb`
- Modify: `app/controllers/api/boards_controller.rb` (add `export_package`)
- Modify: `app/controllers/api/board_groups_controller.rb` (add `export_package`)
- Modify: `config/routes.rb`
- Test: `spec/requests/api/board_exports_spec.rb`

**Interfaces:**
- Consumes: `BoardExport` (Task 7); `Boards::ExportScope` (Task 8); `Boards::ObzPackager` (Task 9)
- Produces:
  - `POST /api/boards/:id/export_package` → `201` with `BoardExport#api_view`
  - `POST /api/board_groups/:id/export_package` → `201` with `BoardExport#api_view`
  - `GET /api/board_exports/:id` → `200` with `BoardExport#api_view`
  - `GET /api/board_exports/:id/download` → the `.obz` bytes
  - Route helper `download_api_board_export_path(record)` (referenced by `BoardExport#api_view` in Task 7)

- [ ] **Step 1: Add the routes**

In `config/routes.rb`, inside the `resources :boards do ... member do` block, below the existing `get "download_obf"` line, add:

```ruby
        post "export_package"
```

Inside the `resources :board_groups` block's `member do` section, add:

```ruby
        post "export_package"
```

Then, as a sibling of `resources :boards` inside the same `namespace :api` block, add:

```ruby
    resources :board_exports, only: [:show] do
      member do
        get "download"
      end
    end
```

- [ ] **Step 2: Verify the route helper the model needs now exists**

Run: `bin/rails routes | grep board_export`
Expected: a row for `download_api_board_export GET /api/board_exports/:id/download`

Run: `bundle exec rspec spec/models/board_export_spec.rb`
Expected: PASS, 4 examples, 0 failures (the `download_url` example now resolves)

- [ ] **Step 3: Write the failing request test**

Create `spec/requests/api/board_exports_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe "API::BoardExports", type: :request do
  let(:user)     { create(:user) }
  let(:stranger) { create(:user) }
  let!(:board)   { create(:board, user: user, name: "Snacks") }

  before do
    allow_any_instance_of(BoardImage).to receive(:tile_image_url).and_return("https://example.test/i.png")
    allow_any_instance_of(BoardImage).to receive(:audio_url).and_return(nil)
  end

  describe "POST /api/boards/:id/export_package" do
    it "returns 401 when unauthenticated" do
      post "/api/boards/#{board.id}/export_package"
      expect(response).to have_http_status(:unauthorized)
    end

    it "creates a queued export and enqueues the job" do
      expect {
        post "/api/boards/#{board.id}/export_package", headers: auth_headers(user)
      }.to change(BoardExport, :count).by(1)

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["status"]).to eq("queued")
    end

    it "returns 404 for a board the user may not read" do
      post "/api/boards/#{board.id}/export_package", headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "GET /api/board_exports/:id" do
    let!(:record) { BoardExport.create!(user: user, exportable: board) }

    it "returns the export status to its owner" do
      get "/api/board_exports/#{record.id}", headers: auth_headers(user)
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["status"]).to eq("queued")
    end

    it "returns 404 to anyone else" do
      get "/api/board_exports/#{record.id}", headers: auth_headers(stranger)
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "ExportBoardPackageJob" do
    let!(:record) { BoardExport.create!(user: user, exportable: board) }

    it "attaches a package and completes" do
      ExportBoardPackageJob.new.perform(record.id)
      record.reload

      expect(record.status).to eq("completed")
      expect(record.file).to be_attached
      expect(record.settings["exported_to_obf"]).to be_present
    end

    it "records a failure instead of raising" do
      allow(Boards::ExportScope).to receive(:for_board).and_raise(StandardError, "kaboom")

      expect { ExportBoardPackageJob.new.perform(record.id) }.not_to raise_error
      expect(record.reload.status).to eq("failed")
      expect(record.error_message).to be_present
    end
  end
end
```

- [ ] **Step 4: Run it to make sure it fails**

Run: `bundle exec rspec spec/requests/api/board_exports_spec.rb`
Expected: FAIL — no `export_package` action, `uninitialized constant ExportBoardPackageJob`

- [ ] **Step 5: Write the job**

Create `app/sidekiq/export_board_package_job.rb`:

```ruby
class ExportBoardPackageJob
  include Sidekiq::Job
  sidekiq_options queue: :default, retry: 1

  def perform(board_export_id)
    record = BoardExport.find_by(id: board_export_id)
    return unless record

    record.mark_processing!

    scope = case record.exportable
      when BoardGroup then Boards::ExportScope.for_group(record.exportable, exporting_user: record.user)
      else Boards::ExportScope.for_board(record.exportable, exporting_user: record.user)
      end

    result = Boards::ObzPackager.new(scope, exporting_user: record.user).call

    record.file.attach(
      io: StringIO.new(result.bytes),
      filename: "#{record.exportable.name.to_s.parameterize.presence || "boards"}.obz",
      content_type: "application/zip",
    )

    settings = record.settings.is_a?(Hash) ? record.settings.dup : {}
    settings["exported_to_obf"] = result.summary
    record.update!(status: "completed", settings: settings)
  rescue Boards::ObzPackager::TooLarge => e
    # Actionable by the user (split the set), so surface it rather than the
    # generic message.
    Rails.logger.warn "[ExportBoardPackageJob] #{e.message}"
    record&.mark_failed!(e.message)
  rescue StandardError => e
    Rails.logger.error "[ExportBoardPackageJob] #{e.class}: #{e.message}"
    record&.mark_failed!("Export failed")
  end
end
```

- [ ] **Step 6: Write the exports controller**

Create `app/controllers/api/board_exports_controller.rb`:

```ruby
class API::BoardExportsController < API::ApplicationController
  before_action :set_board_export

  def show
    render json: @board_export.api_view
  end

  def download
    unless @board_export.completed? && @board_export.file.attached?
      render json: { error: "Export not ready" }, status: :not_found
      return
    end

    send_data @board_export.file.download,
              filename: @board_export.file.filename.to_s,
              type: "application/zip",
              disposition: "attachment"
  end

  private

  # Scoped to the current user, so another user's export is a plain 404 rather
  # than a 403 that confirms it exists.
  def set_board_export
    @board_export = BoardExport.find_by(id: params[:id], user_id: current_user&.id)
    return if @board_export

    render json: { error: "Export not found" }, status: :not_found
  end
end
```

- [ ] **Step 7: Add the two `export_package` actions**

In `app/controllers/api/boards_controller.rb`, add below `download_obf`:

```ruby
  def export_package
    set_board
    return if performed?

    unless @board.viewable_by?(current_user)
      render json: { error: "Board not found" }, status: :not_found
      return
    end

    record = BoardExport.create!(user: current_user, exportable: @board, file_format: "obz")
    ExportBoardPackageJob.perform_async(record.id)

    render json: record.api_view, status: :created
  end
```

In `app/controllers/api/board_groups_controller.rb`, add:

```ruby
  def export_package
    board_group = BoardGroup.find_by(id: params[:id])
    unless board_group
      render json: { error: "Board Group not found" }, status: :not_found
      return
    end
    return unless authorize_board_group_read!(board_group)

    record = BoardExport.create!(user: current_user, exportable: board_group, file_format: "obz")
    ExportBoardPackageJob.perform_async(record.id)

    render json: record.api_view, status: :created
  end
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `bundle exec rspec spec/requests/api/board_exports_spec.rb`
Expected: PASS, 7 examples, 0 failures

- [ ] **Step 9: Commit**

```bash
git add app/sidekiq/export_board_package_job.rb app/controllers/api/board_exports_controller.rb app/controllers/api/boards_controller.rb app/controllers/api/board_groups_controller.rb config/routes.rb spec/requests/api/board_exports_spec.rb
git commit -m "feat(export): add obz export endpoints, job and status polling"
```

---

## Task 11: The round-trip spec

The load-bearing test. Export a board set, feed the bytes straight back into `ObzImporter`, and assert the structure survives. This is the only test that verifies both halves agree, and it is what catches the string-vs-integer grid id class of bug.

**Files:**
- Test: `spec/services/boards/obz_round_trip_spec.rb`

**Interfaces:**
- Consumes: `Boards::ExportScope`, `Boards::ObzPackager`, `ObzImporter`
- Produces: nothing.

- [ ] **Step 1: Write the round-trip test**

Create `spec/services/boards/obz_round_trip_spec.rb`:

```ruby
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
```

- [ ] **Step 2: Run it**

Run: `bundle exec rspec spec/services/boards/obz_round_trip_spec.rb`
Expected: PASS, 2 examples, 0 failures.

If the import returns fewer boards than expected, check the manifest `paths.boards` keys against what `ObzImporter#resolve_obf_paths` reads — it takes `manifest.dig("paths", "boards").values`, so the values must be the zip entry paths.

- [ ] **Step 3: Run the whole affected surface**

Run: `bundle exec rspec spec/services/boards spec/services/images spec/models/board_export_spec.rb spec/models/board_image_obf_format_spec.rb spec/helpers/boards_helper_format_grid_spec.rb spec/requests/api/boards spec/requests/api/board_exports_spec.rb`
Expected: PASS, 0 failures.

- [ ] **Step 4: Commit**

```bash
git add spec/services/boards/obz_round_trip_spec.rb
git commit -m "test(export): add OBZ export/import round-trip spec"
```

---

## Task 12: Documentation

Per the repo conventions, docs ship with the change, not after.

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `.claude-notes/boards-and-teams.md` (the spoke that already covers OBF/OBZ import policy)

- [ ] **Step 1: Add the changelog entry**

At the top of `CHANGELOG.md`, under the current unreleased heading (create one matching the file's existing style if absent):

```markdown
### Added
- Export a board as `.obf`, or a board set / linked board tree as `.obz`.
  Packages bundle image files where SpeakAnyWay may lawfully redistribute
  them and fall back to links otherwise, with a README listing anything
  left out.

### Fixed
- `download_obf` now checks read permission before exporting a board, and
  names the downloaded file after the board.
- OBF grid `order` ids are emitted as strings so they match button ids for
  spec-strict importers.
```

- [ ] **Step 2: Document the invariants in the spoke**

Append to `.claude-notes/boards-and-teams.md`, in the OBF/OBZ section:

```markdown
### OBF/OBZ export

- `Images::RedistributionLicense` gates asset bundling. It is deliberately NOT
  `Images::CommercialLicense`: that one answers "may we SELL this", excludes
  NC/ND, and treats a nil `source_type` as untrusted. For export, NC/ND are
  redistributable and a nil source_type is usually a legacy user upload —
  using the commercial predicate would drop users' own photos from their own
  exports.
- Ownership is checked before license, but a stamped `user_id` is not
  authorship: `Board.from_obf` writes `ObfImport` docs with the importing
  user's id, so ownership additionally requires a user-authored `source_type`
  (`nil`, `""`, or `Doc::SOURCE_TYPE_USER`). Without that restriction an
  import of someone else's proprietary symbols re-exports as the user's own.
- Bundling and the declared license are independent. A board of the user's own
  photos bundles every asset AND declares `"private"` — we have no standing to
  license a user's family photos under CC BY-SA.
- The `.obz` layout is dictated by `ObzImporter`, not chosen freely.
  `spec/services/boards/obz_round_trip_spec.rb` is the contract between them.
- `Boards::PredictiveLinkSet.collect` caps depth only, never board count.
  `Boards::ExportScope::MAX_BOARDS` is what stops a wide graph producing an
  unbounded package.
```

- [ ] **Step 3: Commit**

```bash
git add CHANGELOG.md
git add -f .claude-notes/boards-and-teams.md
git commit -m "docs: record OBF/OBZ export invariants and changelog"
```

---

## Done criteria

- [ ] `bundle exec rspec spec/services spec/models spec/requests spec/helpers` passes with zero failures
- [ ] `spec/services/images/commercial_license_spec.rb` is unmodified and still reports 25 examples
- [ ] The round-trip spec passes
- [ ] `grep -rn "def to_obf\b" app` returns nothing (the helper is gone)
- [ ] A user exporting a board of their own uploaded photos gets every image bundled

## Follow-on

The frontend work (`ExportBoardModal`, the `BoardEditorHeader` action, the Board Set button, api client functions, i18n) is a separate plan in `itty-bitty-frontend`, since it is a different repo, branch and test runner. It depends only on the endpoint contract produced by Task 10.
