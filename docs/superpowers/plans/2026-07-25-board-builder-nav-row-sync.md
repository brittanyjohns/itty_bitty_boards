# Board Builder Nav Row Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Project the root board's final nav row onto every page of a built Board Builder set — including the pages the build itself adds — keep it bottom-pinned on every screen size, and backfill already-built sets.

**Architecture:** Two new services. `Boards::NavRegion` is a pure query that derives the nav region from a root board's `lg` layout (and can rotate the authored nav row back to the bottom). `Boards::NavRowSync` persists that alignment and projects the region onto every child board in the set. `BuildBoardSetJob` calls the sync at its existing end-of-build chokepoint; `Boards::ScreenReflow` gains an opt-in `pinned_rows:` so the region survives the md/sm/xs reflow; a rake task runs the same sync over already-built sets.

**Tech Stack:** Ruby on Rails 8, RSpec, FactoryBot, Sidekiq.

**Spec:** `docs/superpowers/specs/2026-07-25-board-builder-nav-row-sync-design.md`

## Global Constraints

- **The nav region is at most 2 rows:** the authored nav row (pinned to the very bottom) plus at most **1** row of build-added pages directly above it.
- **The self-tile rule:** on any child board, the nav tile whose label case-insensitively matches that board's `name` links to the **root**, not to its own page, and is the one nav tile that is **not** muted.
- **Never drop a user's tile.** A user word tile occupying a target nav cell is **relocated** into the content area. Only stale *folder* tiles are destroyed.
- **`lg` is the source of truth.** All derivation reads `board_image.layout["lg"]`. md/sm/xs are always derived from lg via `Boards::ScreenReflow`.
- **`ScreenReflow` is shared with non-builder boards.** `pinned_rows:` defaults to `0`, and the `0` path must stay byte-identical to today's behavior.
- **Out of scope:** legacy label-only starter templates (`home`, `daily_routine`). The seed `.obf` files are **not** re-authored, and `spec/db/seeds/board_builder_sets_spec.rb` is **not** modified.
- **Backfill defaults to dry-run.** `DRY_RUN=false` to apply, `USER_ID=N` to scope — matching every other task in `lib/tasks/board_builder.rake`.
- Existing BFS helper: `Boards::PredictiveLinkSet.collect(root, max_depth:, exclude:)`. Do **not** write a fourth board-graph walker.

---

### Task 1: `Boards::NavRegion` — derive the nav region

Pure query object. No persistence, no side effects. Everything downstream reads its output, so it lands first and alone.

**Files:**
- Create: `app/services/boards/nav_region.rb`
- Test: `spec/services/boards/nav_region_spec.rb`

**Interfaces:**
- Consumes: nothing (reads `Board#board_images` and `BoardImage#layout`).
- Produces:
  - `Boards::NavRegion::Tile` — `Struct` with members `board_image_id, x, y, w, h, label, target_board_id`.
  - `Boards::NavRegion::Result` — `Struct` with members `rows` (Array&lt;Integer&gt;, ascending y indices), `cells` (Array&lt;Tile&gt;); responds to `empty?` and `row_count`.
  - `Boards::NavRegion.placed_tiles(root) -> Array<Tile>`
  - `Boards::NavRegion.align(tiles) -> Array<Tile>`
  - `Boards::NavRegion.authored_nav_y(tiles) -> Integer | nil`
  - `Boards::NavRegion.for_tiles(tiles) -> Result`
  - `Boards::NavRegion.for_root(root) -> Result` (= `for_tiles(align(placed_tiles(root)))`)

**Background an implementer needs:**

A `BoardImage` stores its grid cell in `layout["lg"]` as `{"i" => id, "x" => 0, "y" => 3, "w" => 1, "h" => 1}`. A tile is a **folder tile** when `predictive_board_id` is present. The authored Core 60 root is 10 columns x 6 rows with its nav row at `y=5`; Core 84 is 12 x 7 with its nav row at `y=6` and one folder tile (`More`) parked outside the nav row at `y=5`.

A build appends new folder tiles (Animals, My Favorites, Phrases) onto a **new row below** the nav row, because `Board#add_image` fills the first open cell and the authored grids are full. `align` rotates the authored nav row back to the bottom so the added row sits above it — which is what the derivation rule in `for_tiles` assumes.

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/nav_region_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Boards::NavRegion do
  let(:user) { create(:user) }
  let(:root) { create(:board, user: user, large_screen_columns: 10) }

  # A tile at an exact lg cell. update_column bypasses the layout callbacks so
  # x/y stay precisely where the test puts them.
  def tile(label, x:, y:, position:, target: nil)
    bi = create(:board_image, board: root, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, predictive_board_id: target)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  # A miniature Core 60: one content row, then a nav row of 4 folders flanked
  # by the `this`/`that` word tiles.
  def build_core_60!
    pos = 0
    %w[I want go stop like have].each_with_index do |label, x|
      tile(label, x: x, y: 0, position: pos += 1)
    end
    tile("this", x: 0, y: 1, position: pos += 1)
    %w[People Feelings Food Drinks].each_with_index do |label, i|
      page = create(:board, user: user, name: label)
      tile(label, x: i + 1, y: 1, position: pos += 1, target: page.id)
    end
    tile("that", x: 5, y: 1, position: pos += 1)
  end

  describe ".for_root" do
    it "treats the bottom row as the nav region" do
      build_core_60!

      result = described_class.for_root(root)

      expect(result.rows).to eq([1])
      expect(result.row_count).to eq(1)
      expect(result.cells.map(&:label)).to contain_exactly(
        "this", "People", "Feelings", "Food", "Drinks", "that"
      )
    end

    it "includes an all-folder row above the nav row as the added row" do
      build_core_60!
      %w[Animals Phrases].each_with_index do |label, i|
        page = create(:board, user: user, name: label)
        tile(label, x: i, y: 2, position: 100 + i, target: page.id)
      end

      result = described_class.for_root(root)

      # y=2 is all folders, so it aligns to sit ABOVE the rotated nav row.
      expect(result.rows).to eq([1, 2])
      expect(result.cells.map(&:label)).to include("Animals", "Phrases", "People", "that")
    end

    it "does not swallow a content row that merely contains a folder tile" do
      build_core_60!
      # Core 84's `More`: a lone folder tile parked in a row of words.
      more_page = create(:board, user: user, name: "More")
      tile("More", x: 6, y: 0, position: 200, target: more_page.id)

      result = described_class.for_root(root)

      expect(result.rows).to eq([1])                       # y=0 is NOT a nav row
      expect(result.cells.map(&:label)).to include("More") # but More is pinned
      expect(result.cells.map(&:label)).not_to include("I", "want")
    end

    it "returns an empty result for a board with no folder tiles" do
      tile("apple", x: 0, y: 0, position: 1)

      expect(described_class.for_root(root)).to be_empty
    end
  end

  describe ".align" do
    it "rotates the authored nav row to the bottom and lifts the rows below it" do
      build_core_60!
      page = create(:board, user: user, name: "Animals")
      tile("Animals", x: 0, y: 2, position: 100, target: page.id)

      aligned = described_class.align(described_class.placed_tiles(root))
      by_label = aligned.index_by(&:label)

      expect(by_label["Animals"].y).to eq(1) # lifted
      expect(by_label["People"].y).to eq(2)  # nav row now last
      expect(by_label["I"].y).to eq(0)       # content untouched
    end

    it "is a no-op when the nav row is already last" do
      build_core_60!
      tiles = described_class.placed_tiles(root)

      expect(described_class.align(tiles).map(&:y)).to eq(tiles.map(&:y))
    end
  end

  describe ".authored_nav_y" do
    it "picks the row with the most folder tiles" do
      build_core_60!
      page = create(:board, user: user, name: "Animals")
      tile("Animals", x: 0, y: 2, position: 100, target: page.id)

      expect(described_class.authored_nav_y(described_class.placed_tiles(root))).to eq(1)
    end

    it "breaks ties toward the lowest row index" do
      a = create(:board, user: user, name: "A")
      b = create(:board, user: user, name: "B")
      tile("A", x: 0, y: 1, position: 1, target: a.id)
      tile("B", x: 0, y: 4, position: 2, target: b.id)

      expect(described_class.authored_nav_y(described_class.placed_tiles(root))).to eq(1)
    end
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards/nav_region_spec.rb`
Expected: FAIL — `uninitialized constant Boards::NavRegion`

- [ ] **Step 3: Write the implementation**

Create `app/services/boards/nav_region.rb`:

```ruby
module Boards
  # Derives a built set's NAV REGION from its root board's `lg` layout.
  #
  # The nav region is the strip of category tiles reproduced cell-for-cell on
  # every page of the set, so a category is the same reach no matter which page
  # you're on (motor planning — an AAC user learns WHERE a word is). See
  # db/seeds/board_builder_sets/README.md for the authoring rule this mirrors.
  #
  # Pure query: reads layouts, returns structs, never writes. Boards::NavRowSync
  # is what persists anything.
  module NavRegion
    module_function

    # A build appends new folder tiles onto a new row BELOW the authored nav
    # row (Board#add_image fills the first open cell, and the authored Core
    # 60/84 grids are full). We allow at most this many such rows to join the
    # nav region; the rest stay reachable from the home board only.
    MAX_ADDED_ROWS = 1

    Tile = Struct.new(:board_image_id, :x, :y, :w, :h, :label, :target_board_id,
                      keyword_init: true)

    Result = Struct.new(:rows, :cells, keyword_init: true) do
      def empty? = cells.empty?
      def row_count = rows.size
      def top_y = rows.first
    end

    EMPTY = Result.new(rows: [], cells: [])

    def for_root(root)
      for_tiles(align(placed_tiles(root)))
    end

    # Every tile on the board that has an lg cell, in authored order.
    def placed_tiles(root)
      root.board_images.order(:position).filter_map do |bi|
        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        next if cell.nil?

        Tile.new(
          board_image_id: bi.id,
          x: cell["x"].to_i,
          y: cell["y"].to_i,
          w: [cell["w"].to_i, 1].max,
          h: [cell["h"].to_i, 1].max,
          label: bi.label.to_s,
          target_board_id: bi.predictive_board_id,
        )
      end
    end

    # The authored nav row: the row holding the most folder tiles. Ties resolve
    # to the LOWEST row index, so a pathological build that added more folder
    # tiles than the authored row holds still can't steal the title.
    def authored_nav_y(tiles)
      folders = tiles.select(&:target_board_id)
      return nil if folders.empty?

      folders.group_by(&:y).max_by { |y, group| [group.size, -y] }.first
    end

    # Rotate the authored nav row back to the bottom: it stays the last row
    # (so `People` never moves), and the build's added rows lift to sit above
    # it. Returns a new tile list; the input is not mutated.
    def align(tiles)
      return tiles if tiles.empty?

      nav_y = authored_nav_y(tiles)
      return tiles if nav_y.nil?

      last_y = tiles.map(&:y).max
      return tiles if nav_y == last_y

      tiles.map do |t|
        new_y =
          if t.y == nav_y then last_y
          elsif t.y > nav_y then t.y - 1
          else t.y
          end

        Tile.new(**t.to_h.merge(y: new_y))
      end
    end

    # Nav rows are the bottom row, plus (going up, capped at MAX_ADDED_ROWS)
    # each immediately preceding row whose occupied cells are ALL folder tiles.
    # That "all folders" test is what keeps a content row holding one stray
    # folder tile — Core 84's `More` — out of the region; it's pinned instead.
    def for_tiles(tiles)
      return EMPTY if tiles.empty? || tiles.none?(&:target_board_id)

      by_row = tiles.group_by(&:y)
      last_y = by_row.keys.max
      rows = [last_y]

      MAX_ADDED_ROWS.times do
        candidate = rows.first - 1
        row = by_row[candidate]
        break if row.nil? || row.empty?
        break unless row.all?(&:target_board_id)

        rows.unshift(candidate)
      end

      top_y = rows.first
      cells = tiles.select { |t| rows.include?(t.y) || (t.y < top_y && t.target_board_id) }

      Result.new(rows: rows, cells: cells)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards/nav_region_spec.rb`
Expected: PASS — 8 examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add app/services/boards/nav_region.rb spec/services/boards/nav_region_spec.rb
git commit -m "feat(board-builder): derive the nav region from a set's root board"
```

---

### Task 2: `Boards::NavRowSync` — project the region onto every page

**Files:**
- Create: `app/services/boards/nav_row_sync.rb`
- Test: `spec/services/boards/nav_row_sync_spec.rb`

**Interfaces:**
- Consumes: `Boards::NavRegion.{placed_tiles,align,for_tiles}` and `Boards::NavRegion::Result` from Task 1; `Boards::PredictiveLinkSet.collect(root, max_depth:, exclude:)`; `Boards::ImageResolver.resolve(label, owner:)`; `Boards::LayoutRepacker.resync_board_layout!(board)`.
- Produces:
  - `Boards::NavRowSync.call(root, dry_run: false) -> Result`
  - `Boards::NavRowSync::Result` — `Struct` with members `boards_synced, tiles_written, folders_deleted, words_relocated`.
  - `Boards::NavRowSync::NAV_TILE_KEY` — the string `"nav_tile"`, the `board_image.data` flag marking a tile this service owns.

**Background an implementer needs:**

- `Boards::PredictiveLinkSet.collect` returns the root first, then every board reachable through `predictive_board_id`, cycle-safe. Pass `max_depth: 2` (Phrases sits at depth 1, the GLP function boards at depth 2) and an `exclude:` that vetoes boards owned by anyone but the root's owner, so a tile pointing at an admin seed board can't pull it in.
- `Board#add_image(image_id)` appends a tile and assigns it an initial layout. This service overwrites that layout immediately, so the initial placement doesn't matter.
- `Boards::ImageResolver.resolve(label, owner:)` returns the curated art-bearing `Image` for a label, creating a blank one only as a last resort. `BoardImage#set_defaults` derives the tile label from its image, so the authored label must be re-pinned explicitly after save — this is an established trap in this codebase (see `BuildBoardSetJob#add_folder_tile!`).
- Muting: a folder tile carries `data["mute_name"] = true` so tapping it navigates without speaking. The **self-tile is the exception** — it speaks its label. This service sets both, and `BuildBoardSetJob#mute_dynamic_tile_names!` (which runs after it) is idempotent over the result.

- [ ] **Step 1: Write the failing test**

Create `spec/services/boards/nav_row_sync_spec.rb`:

```ruby
require "rails_helper"

RSpec.describe Boards::NavRowSync do
  let(:user) { create(:user) }
  let!(:root) { create(:board, user: user, name: "Core 60", large_screen_columns: 6) }
  let!(:food) { create(:board, user: user, name: "Food", large_screen_columns: 6) }
  let!(:drinks) { create(:board, user: user, name: "Drinks", large_screen_columns: 6) }

  def tile(board, label, x:, y:, position:, target: nil, data: {})
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, predictive_board_id: target, data: data)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  # Root: a content row, then a nav row of `this | Food | Drinks | that`.
  before do
    %w[I want go stop].each_with_index { |l, x| tile(root, l, x: x, y: 0, position: x + 1) }
    tile(root, "this", x: 0, y: 1, position: 10)
    tile(root, "Food", x: 1, y: 1, position: 11, target: food.id)
    tile(root, "Drinks", x: 2, y: 1, position: 12, target: drinks.id)
    tile(root, "that", x: 3, y: 1, position: 13)
  end

  def nav_cells(board)
    board.board_images.reload.select { |bi| bi.data&.dig("nav_tile") }.map do |bi|
      { label: bi.label, x: bi.layout["lg"]["x"], y: bi.layout["lg"]["y"],
        target: bi.predictive_board_id, muted: bi.data["mute_name"] }
    end.sort_by { |c| [c[:y], c[:x]] }
  end

  it "projects the root's nav row onto every child at the same cells" do
    described_class.call(root)

    expect(nav_cells(food).map { |c| [c[:label], c[:x], c[:y]] }).to eq(
      [["this", 0, 1], ["Food", 1, 1], ["Drinks", 2, 1], ["that", 3, 1]]
    )
  end

  it "points the self-tile at the root and leaves it unmuted" do
    described_class.call(root)

    self_tile = nav_cells(food).find { |c| c[:label] == "Food" }
    other     = nav_cells(food).find { |c| c[:label] == "Drinks" }

    expect(self_tile[:target]).to eq(root.id)
    expect(self_tile[:muted]).to be_falsey
    expect(other[:target]).to eq(drinks.id)
    expect(other[:muted]).to be(true)
  end

  it "is idempotent" do
    described_class.call(root)
    first = nav_cells(food)

    expect { described_class.call(root) }.not_to change { food.board_images.reload.count }
    expect(nav_cells(food)).to eq(first)
  end

  it "deletes a stale nav folder tile that is no longer in the region" do
    stale_page = create(:board, user: user, name: "Home")
    tile(food, "Home", x: 0, y: 1, position: 1, target: stale_page.id)

    result = described_class.call(root)

    expect(food.board_images.reload.map(&:label)).not_to include("Home")
    expect(result.folders_deleted).to eq(1)
  end

  it "relocates a user's word tile out of a nav cell instead of deleting it" do
    tile(food, "pizza", x: 1, y: 1, position: 1)

    result = described_class.call(root)

    pizza = food.board_images.reload.find { |bi| bi.label == "pizza" }
    expect(pizza).to be_present                       # never dropped
    expect(pizza.layout["lg"]["y"]).to be < 1         # moved into the content area
    expect(result.words_relocated).to eq(1)
  end

  it "reaches depth-2 boards" do
    greetings = create(:board, user: user, name: "Greetings", large_screen_columns: 6)
    phrases   = create(:board, user: user, name: "Phrases", large_screen_columns: 6)
    tile(root, "Phrases", x: 4, y: 1, position: 14, target: phrases.id)
    tile(phrases, "Greetings", x: 0, y: 0, position: 1, target: greetings.id)

    described_class.call(root)

    expect(nav_cells(greetings).map { |c| c[:label] }).to include("Food", "Drinks", "Phrases")
  end

  it "writes nothing on a dry run but still reports the work" do
    result = described_class.call(root, dry_run: true)

    expect(food.board_images.reload).to be_empty
    expect(result.boards_synced).to eq(2)         # Food + Drinks
    expect(result.tiles_written).to eq(8)         # 4 nav cells x 2 pages
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards/nav_row_sync_spec.rb`
Expected: FAIL — `uninitialized constant Boards::NavRowSync`

- [ ] **Step 3: Write the implementation**

Create `app/services/boards/nav_row_sync.rb`:

```ruby
module Boards
  # Projects a built set's NAV REGION (Boards::NavRegion) onto every page in
  # the set, so a category is the same reach from anywhere. The tile matching
  # the page you're on links back to the ROOT — the you-are-here anchor and the
  # way home — and is the one nav tile that speaks its label.
  #
  # Authoring the nav row in the seed .obf files (see
  # db/seeds/board_builder_sets/README.md) can only cover the pages that ship
  # IN the seed set. This covers the pages a build ADDS — prebuilt fringe,
  # AI-generated, My Favorites, Phrases, the GLP function boards — and repairs
  # the seeded pages whose nav row went stale when the build grew the root.
  #
  # Idempotent: tiles this service owns carry data["nav_tile"] = true.
  class NavRowSync
    MAX_DEPTH = 2
    NAV_TILE_KEY = "nav_tile".freeze

    Result = Struct.new(:boards_synced, :tiles_written, :folders_deleted,
                        :words_relocated, keyword_init: true)

    def self.call(root, dry_run: false)
      new(root, dry_run: dry_run).call
    end

    def initialize(root, dry_run: false)
      @root = root
      @dry_run = dry_run
      @result = Result.new(boards_synced: 0, tiles_written: 0,
                           folders_deleted: 0, words_relocated: 0)
    end

    def call
      tiles   = Boards::NavRegion.align(Boards::NavRegion.placed_tiles(@root))
      @region = Boards::NavRegion.for_tiles(tiles)
      return @result if @region.empty?

      persist_alignment!(tiles) unless @dry_run
      children.each { |child| sync_child!(child) }
      @result
    end

    private

    attr_reader :region

    # `align` may have rotated the authored nav row back to the bottom; write
    # those new y values onto the root before anything reads its layout again.
    def persist_alignment!(tiles)
      changed = false
      tiles.each do |t|
        bi = BoardImage.find_by(id: t.board_image_id)
        next if bi.nil?

        cell = (bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil) || {}
        next if cell["y"].to_i == t.y

        bi.layout = (bi.layout || {}).merge("lg" => cell.merge("y" => t.y))
        bi.save!
        changed = true
      end
      Boards::LayoutRepacker.resync_board_layout!(@root) if changed
    end

    def children
      Boards::PredictiveLinkSet
        .collect(@root, max_depth: MAX_DEPTH, exclude: ->(b) { b.user_id != @root.user_id })
        .reject { |b| b.id == @root.id }
    end

    def sync_child!(child)
      @result.boards_synced += 1

      if @dry_run
        @result.tiles_written += region.cells.size
        return
      end

      child.update_column(:large_screen_columns, @root.large_screen_columns) if @root.large_screen_columns.to_i.positive?

      evict_occupants!(child)
      drop_orphaned_nav_tiles!(child)
      region.cells.each { |cell| upsert_nav_tile!(child, cell) }

      child.board_images.reset
      Boards::LayoutRepacker.resync_board_layout!(child)
    end

    # Clear the cells the nav region needs. Stale FOLDER tiles (the pre-sync
    # `Home` tile, the old shifted categories) are destroyed. A user's WORD
    # tile is moved into the content area — never dropped.
    def evict_occupants!(child)
      targets = region.cells.map { |c| [c.x, c.y] }.to_set

      child.board_images.reload.each do |bi|
        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        next if cell.nil?
        next unless targets.include?([cell["x"].to_i, cell["y"].to_i])
        next if bi.data&.dig(NAV_TILE_KEY) # ours; upsert handles it

        if bi.predictive_board_id.present?
          bi.destroy!
          @result.folders_deleted += 1
        else
          relocate!(child, bi)
          @result.words_relocated += 1
        end
      end
    end

    # First free cell strictly above the nav region. When the content area is
    # full, push the nav region down a row and take the row that frees up, so a
    # relocated tile is never dropped for want of space.
    def relocate!(child, board_image)
      columns = [child.large_screen_columns.to_i, 1].max
      occupied = occupied_cells(child, except: board_image.id)

      (0...region.top_y).each do |y|
        (0...columns).each do |x|
          next if occupied.include?([x, y])

          write_cell!(board_image, x, y)
          return
        end
      end

      shift_region_down!(child)
      write_cell!(board_image, 0, region.top_y)
    end

    def shift_region_down!(child)
      child.board_images.reload.each do |bi|
        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        next if cell.nil? || cell["y"].to_i < region.top_y

        write_cell!(bi, cell["x"].to_i, cell["y"].to_i + 1)
      end
    end

    def occupied_cells(child, except: nil)
      child.board_images.reload.each_with_object(Set.new) do |bi, acc|
        next if bi.id == except

        cell = bi.layout.is_a?(Hash) ? bi.layout["lg"] : nil
        acc << [cell["x"].to_i, cell["y"].to_i] if cell
      end
    end

    def write_cell!(board_image, x, y)
      cell = (board_image.layout.is_a?(Hash) ? board_image.layout["lg"] : nil) || {}
      board_image.layout = (board_image.layout || {}).merge(
        "lg" => cell.merge("i" => board_image.id.to_s, "x" => x, "y" => y,
                           "w" => [cell["w"].to_i, 1].max, "h" => [cell["h"].to_i, 1].max),
      )
      board_image.save!
    end

    # A nav tile we own whose label left the region (the root dropped a page).
    def drop_orphaned_nav_tiles!(child)
      labels = region.cells.map { |c| c.label.downcase }.to_set

      child.board_images.reload.each do |bi|
        next unless bi.data&.dig(NAV_TILE_KEY)
        next if labels.include?(bi.label.to_s.downcase)

        bi.destroy!
        @result.folders_deleted += 1
      end
    end

    def upsert_nav_tile!(child, cell)
      existing = child.board_images.reload.find do |bi|
        bi.data&.dig(NAV_TILE_KEY) && bi.label.to_s.casecmp?(cell.label)
      end

      board_image = existing || begin
        image = Boards::ImageResolver.resolve(cell.label, owner: child.user)
        child.add_image(image.id)
      end
      return if board_image.nil?

      self_tile = cell.label.to_s.strip.casecmp?(child.name.to_s.strip)
      data = (board_image.data || {}).merge(NAV_TILE_KEY => true)
      # Folder tiles navigate silently; the self-tile speaks its own label.
      data = self_tile ? data.except("mute_name") : data.merge("mute_name" => true)

      board_image.update!(
        # BoardImage#set_defaults derives the label from the resolved Image
        # (often lowercase art), so the authored name is re-pinned explicitly.
        label: cell.label,
        display_label: cell.label,
        predictive_board_id: self_tile ? @root.id : cell.target_board_id,
        data: data,
      )
      write_cell!(board_image, cell.x, cell.y)
      @result.tiles_written += 1
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards/nav_row_sync_spec.rb`
Expected: PASS — 8 examples, 0 failures

- [ ] **Step 5: Run Task 1's spec to confirm no regression**

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards/nav_region_spec.rb spec/services/boards/nav_row_sync_spec.rb`
Expected: PASS — 16 examples, 0 failures

- [ ] **Step 6: Commit**

```bash
git add app/services/boards/nav_row_sync.rb spec/services/boards/nav_row_sync_spec.rb
git commit -m "feat(board-builder): project the root nav row onto every page in a set"
```

---

### Task 3: Keep the nav region bottom-pinned on md / sm / xs

`Boards::ScreenReflow` is shared with every board in the app, so this task lands on its own with a spec that proves the default path is unchanged.

**Files:**
- Modify: `app/services/boards/screen_reflow.rb:28-51`
- Test: `spec/services/boards/screen_reflow_spec.rb`

**Interfaces:**
- Consumes: `Boards::NavRegion::Result#row_count` from Task 1.
- Produces: `Boards::ScreenReflow.reflow!(board, screens:, dry_run:, pinned_rows: 0)` — when `pinned_rows` is positive, the tiles occupying the bottom `pinned_rows` rows of the **lg** layout are packed last and bottom-aligned on each derived screen.

**Background an implementer needs:**

`reflow!` today packs every tile in lg reading order into the derived column count. A 10-tile nav row therefore lands wherever the packer puts it — mid-board on a phone. With `pinned_rows: 1` the content tiles pack first, then the nav tiles pack into the rows below them.

At 4 columns a 10-tile nav row necessarily becomes 3 rows. That is expected and accepted: it is still bottom-pinned and still identical on every page in the set.

- [ ] **Step 1: Write the failing test**

Append to `spec/services/boards/screen_reflow_spec.rb`, inside the top-level `RSpec.describe`:

```ruby
  describe "pinned_rows" do
    # 3 content tiles on y=0, then a 4-tile nav row on y=1.
    before do
      %w[I want go].each_with_index { |l, x| tile(l, x: x, y: 0, position: x + 1) }
      %w[Food Drinks Play More].each_with_index { |l, x| tile(l, x: x, y: 1, position: x + 10) }
    end

    def labels_at(screen)
      board.board_images.reload.map { |bi| [bi.label, bi.layout[screen]] }.to_h
    end

    it "leaves the default path byte-identical" do
      described_class.reflow!(board)
      default = labels_at("sm")

      board.board_images.each { |bi| bi.update_column(:layout, bi.layout.slice("lg")) }
      described_class.reflow!(board, pinned_rows: 0)

      expect(labels_at("sm")).to eq(default)
    end

    it "packs the pinned rows below every content tile on sm" do
      described_class.reflow!(board, pinned_rows: 1)

      cells = labels_at("sm")
      content_bottom = %w[I want go].map { |l| cells[l]["y"] }.max
      nav_top = %w[Food Drinks Play More].map { |l| cells[l]["y"] }.min

      expect(nav_top).to be > content_bottom
    end

    it "keeps every tile and never overlaps at 4 columns" do
      described_class.reflow!(board, pinned_rows: 1)

      expect_valid_layout("sm", 4, 7)
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards/screen_reflow_spec.rb -e "pinned_rows"`
Expected: FAIL — `unknown keyword: :pinned_rows`

- [ ] **Step 3: Write the implementation**

In `app/services/boards/screen_reflow.rb`, replace `reflow!` (lines 24-51) with:

```ruby
    # Reflow the given screens from lg and persist. `screens` defaults to md+sm
    # but a caller can narrow it (e.g. to skip a screen the user hand-arranged).
    # Returns the list of screens rewritten (empty when there's nothing to do).
    # Pass dry_run: true to compute without saving.
    #
    # `pinned_rows` (Board Builder): the number of rows at the BOTTOM of the lg
    # grid that form the set's nav region (Boards::NavRegion). Those tiles pack
    # last so the nav strip stays bottom-pinned on tablets and phones instead of
    # wrapping into the middle of the board. At a narrow column count the strip
    # necessarily spans more rows — still bottom-pinned, still identical on
    # every page of the set. `0` (the default) is the original code path.
    def reflow!(board, screens: DERIVED_SCREENS, dry_run: false, pinned_rows: 0)
      screens = Array(screens) & DERIVED_SCREENS
      return [] if screens.empty?

      ordered = lg_reading_order(board)
      return [] if ordered.empty?

      return screens if dry_run

      pinned_ids = pinned_row_ids(ordered, pinned_rows)
      content = ordered.reject { |bi| pinned_ids.include?(bi.id) }
      pinned  = ordered.select { |bi| pinned_ids.include?(bi.id) }

      screens.each do |screen|
        columns = board.get_number_of_columns(screen).to_i
        columns = 1 if columns < 1
        packed = pack(content, columns)
        packed += pack_below(pinned, columns, packed) if pinned.any?

        apply_screen!(packed, screen)
        SM_MIRRORS.each { |mirror| apply_screen!(packed, mirror) } if screen == "sm"
      end

      # Rebuild the denormalized board.layout (lg/md/sm) from the now-updated
      # per-tile layouts, reusing the single writer so the shape stays in lockstep.
      board.board_images.reset
      Boards::LayoutRepacker.resync_board_layout!(board)
      screens
    end

    # board_image ids occupying the bottom `count` rows of the lg grid.
    def pinned_row_ids(ordered, count)
      return [] unless count.to_i.positive?

      rows = ordered.filter_map { |bi| bi.layout.is_a?(Hash) ? bi.layout.dig("lg", "y")&.to_i : nil }
      return [] if rows.empty?

      cutoff = rows.max - count.to_i + 1
      ordered.select { |bi| (bi.layout.is_a?(Hash) ? bi.layout.dig("lg", "y")&.to_i : nil).to_i >= cutoff }
        .map(&:id)
    end
    private_class_method :pinned_row_ids

    # Pack the pinned tiles into fresh rows below everything already placed.
    def pack_below(pinned, columns, placed)
      offset = placed.map { |e| e[:cell]["y"] + e[:cell]["h"] }.max || 0
      pack(pinned, columns).each do |entry|
        entry[:cell]["y"] += offset
      end
    end
    private_class_method :pack_below
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `RAILS_ENV=test bundle exec rspec spec/services/boards/screen_reflow_spec.rb`
Expected: PASS — all examples, 0 failures (the pre-existing examples confirm the `pinned_rows: 0` path is untouched)

- [ ] **Step 5: Commit**

```bash
git add app/services/boards/screen_reflow.rb spec/services/boards/screen_reflow_spec.rb
git commit -m "feat(board-builder): keep the nav region bottom-pinned on md/sm/xs"
```

---

### Task 4: Wire the sync into `BuildBoardSetJob`

**Files:**
- Modify: `app/sidekiq/build_board_set_job.rb:74-84` (the chokepoint) and `:232-238` (`reflow_screen_layouts!`)
- Test: `spec/sidekiq/build_board_set_job_spec.rb`

**Interfaces:**
- Consumes: `Boards::NavRowSync.call(root)` (Task 2), `Boards::NavRegion.for_root(root)` (Task 1), `Boards::ScreenReflow.reflow!(board, pinned_rows:)` (Task 3).
- Produces: nothing new for other tasks.

**Background an implementer needs:**

The chokepoint runs after both build branches (`build_with_structure_planner` and `build_legacy`), so one call covers every path. Ordering is load-bearing — the sync must run **before** muting, reflow, sub-board previews, and preview generation, so all four observe the final grid.

Legacy label-only starter templates (`home`, `daily_routine`) are out of scope. The guard reads the job's own `level_or_template` argument rather than inspecting markers on the cloned root, so it is unambiguous: a complexity level always clones a robust set, and a legacy robust key resolves through `Boards::RobustSets.find_root`.

- [ ] **Step 1: Write the failing test**

Append to `spec/sidekiq/build_board_set_job_spec.rb`, inside the top-level `RSpec.describe`:

```ruby
  describe "nav row sync" do
    it "gives every page in the set the root's nav row, with a self-tile home" do
      described_class.new.perform(root.id, communicator.id, "standard", %w[dinosaurs])

      root.reload
      region = Boards::NavRegion.for_root(root)
      expect(region).not_to be_empty

      child_ids = Boards::PredictiveLinkSet
        .collect(root, max_depth: 2, exclude: ->(b) { b.user_id != root.user_id })
        .reject { |b| b.id == root.id }
      expect(child_ids).not_to be_empty

      child_ids.each do |child|
        nav = child.board_images.select { |bi| bi.data&.dig("nav_tile") }
        expect(nav.map(&:label)).to match_array(region.cells.map(&:label)),
                                    "#{child.name} is missing nav tiles"

        self_tile = nav.find { |bi| bi.label.to_s.casecmp?(child.name.to_s) }
        next if self_tile.nil? # a page with no tile of its own name in the region

        expect(self_tile.predictive_board_id).to eq(root.id)
        expect(self_tile.data["mute_name"]).to be_falsey
      end
    end

    it "does not sync legacy starter templates" do
      expect(Boards::NavRowSync).not_to receive(:call)

      described_class.new.perform(root.id, communicator.id, "home", [])
    end
  end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `RAILS_ENV=test bundle exec rspec spec/sidekiq/build_board_set_job_spec.rb -e "nav row sync"`
Expected: FAIL — no `nav_tile` tiles on the child boards

- [ ] **Step 3: Write the implementation**

In `app/sidekiq/build_board_set_job.rb`, in `perform`, insert the sync between `attach_set_to_group!` and `mute_dynamic_tile_names!`:

```ruby
      attach_set_to_group!(root, board_group_id)
      sync_nav_rows!(root, level_or_template)
      mute_dynamic_tile_names!(root)
      classify_sub_boards!(root)
      reflow_screen_layouts!(root)
      set_sub_board_previews_from_tiles!(root)
      generate_preview!(root)
```

Add the private method (next to `mute_dynamic_tile_names!`):

```ruby
  # Project the root's FINAL nav row onto every page in the set. Authoring it
  # in the seed .obf files only covers the pages that ship in the seed set —
  # the pages this build added (prebuilt fringe, AI, My Favorites, Phrases, the
  # GLP function boards) have none, and adding any of them pushes the root's
  # grid out of alignment with the seeded pages. Runs BEFORE muting, reflow,
  # and preview generation so all three see the final grid.
  #
  # Robust sets only: the legacy label-only starter trees (home, daily_routine)
  # have no nav row concept. Reading the job's own argument keeps the guard
  # unambiguous — a complexity level always clones a robust set.
  def sync_nav_rows!(root, level_or_template)
    return unless complexity_level?(level_or_template) ||
                  Boards::RobustSets.find_root(level_or_template).present?

    Boards::NavRowSync.call(root)
  rescue => e
    Rails.logger.error "BuildBoardSetJob #{root.id}: nav row sync failed: #{e.message}"
  end
```

Then replace `reflow_screen_layouts!` so the region survives the responsive reflow:

```ruby
  def reflow_screen_layouts!(root)
    pinned_rows = Boards::NavRegion.for_root(root.reload).row_count

    Board.where(id: set_board_ids(root)).find_each do |board|
      Boards::ScreenReflow.reflow!(board, pinned_rows: pinned_rows)
    rescue => e
      Rails.logger.error "BuildBoardSetJob #{root.id}: screen reflow failed for board #{board.id}: #{e.message}"
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `RAILS_ENV=test bundle exec rspec spec/sidekiq/build_board_set_job_spec.rb`
Expected: PASS — all examples, 0 failures

- [ ] **Step 5: Commit**

```bash
git add app/sidekiq/build_board_set_job.rb spec/sidekiq/build_board_set_job_spec.rb
git commit -m "feat(board-builder): sync nav rows at the end of every robust-set build"
```

---

### Task 5: `rake board_builder:sync_nav_rows` backfill

**Files:**
- Modify: `lib/tasks/board_builder.rake` (append a task in the existing `board_builder` namespace)
- Test: `spec/tasks/board_builder_sync_nav_rows_spec.rb`

**Interfaces:**
- Consumes: `Boards::NavRowSync.call(root, dry_run:)` (Task 2).
- Produces: nothing for other tasks.

**Background an implementer needs:**

Sets built before this feature carry the pre-#521 layout (a `Home` tile plus shifted categories) and are clones, so re-seeding the authored templates never reaches them. This task is what heals them.

Follow the conventions already in this file: `dry_run = ENV["DRY_RUN"] != "false"`, an optional `USER_ID=N` scope, a per-set `puts`, and a closing summary line telling the operator how to apply.

Only regenerate previews for boards the sync actually changed — a full-set preview regeneration across every built set is expensive.

- [ ] **Step 1: Write the failing test**

Create `spec/tasks/board_builder_sync_nav_rows_spec.rb`:

```ruby
require "rails_helper"
require "rake"

RSpec.describe "board_builder:sync_nav_rows" do
  before(:all) do
    Rake.application.rake_require("tasks/board_builder") unless Rake::Task.task_defined?("board_builder:sync_nav_rows")
    Rake::Task.define_task(:environment)
  end

  let(:task) { Rake::Task["board_builder:sync_nav_rows"] }
  let(:user) { create(:user) }
  let!(:root) do
    create(:board, user: user, name: "Core 60", large_screen_columns: 4,
                   settings: { "builder_root" => true })
  end
  let!(:food) { create(:board, user: user, name: "Food", large_screen_columns: 4) }

  def tile(board, label, x:, y:, position:, target: nil)
    bi = create(:board_image, board: board, position: position,
                              image: create(:image, label: label, user_id: user.id))
    bi.update_columns(label: label, predictive_board_id: target)
    bi.update_column(:layout, { "lg" => { "i" => bi.id.to_s, "x" => x, "y" => y, "w" => 1, "h" => 1 } })
    bi
  end

  before do
    tile(root, "I", x: 0, y: 0, position: 1)
    tile(root, "this", x: 0, y: 1, position: 2)
    tile(root, "Food", x: 1, y: 1, position: 3, target: food.id)
    task.reenable
  end

  after { ENV.delete("DRY_RUN") }

  it "writes nothing by default" do
    expect { task.invoke }.to output(/Dry run only/).to_stdout
    expect(food.board_images.reload).to be_empty
  end

  it "applies with DRY_RUN=false" do
    ENV["DRY_RUN"] = "false"

    expect { task.invoke }.to output(/Synced/).to_stdout
    expect(food.board_images.reload.map(&:label)).to include("Food", "this")
  end
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `RAILS_ENV=test bundle exec rspec spec/tasks/board_builder_sync_nav_rows_spec.rb`
Expected: FAIL — `Don't know how to build task 'board_builder:sync_nav_rows'`

- [ ] **Step 3: Write the implementation**

Append inside the `namespace :board_builder do` block in `lib/tasks/board_builder.rake`, before the `builder_set_child_ids` helper:

```ruby
  # Backfill for the nav-row sync. Sets built before it landed carry the old
  # per-page nav row (a `Home` tile plus categories shifted left to fill the
  # gap), and built sets are clones — re-seeding the authored templates never
  # reaches them. This re-projects each root's nav row onto every page of its
  # set: stale folder tiles are removed, a user's word tile in a nav cell is
  # relocated rather than deleted.
  #
  # Read-only by default. Apply with DRY_RUN=false; scope with USER_ID=N:
  #   rake board_builder:sync_nav_rows                       # preview all
  #   DRY_RUN=false rake board_builder:sync_nav_rows         # apply all
  #   DRY_RUN=false USER_ID=740 rake board_builder:sync_nav_rows
  desc "Re-project the nav row onto every page of each built set (DRY_RUN=false to apply; USER_ID=N to scope)"
  task sync_nav_rows: :environment do
    dry_run = ENV["DRY_RUN"] != "false"

    roots = Board.where("(settings ->> 'builder_root') = 'true'")
    roots = roots.where(user_id: ENV["USER_ID"]) if ENV["USER_ID"].present?

    sets = 0
    tiles = 0
    folders = 0
    words = 0

    roots.find_each do |root|
      result = Boards::NavRowSync.call(root, dry_run: dry_run)
      next if result.boards_synced.zero?

      sets += 1
      tiles += result.tiles_written
      folders += result.folders_deleted
      words += result.words_relocated

      puts "#{dry_run ? '[DRY RUN] ' : ''}set ##{root.id} #{root.name.inspect} (owner #{root.user_id}): " \
           "#{result.boards_synced} page(s), #{result.tiles_written} nav tile(s), " \
           "#{result.folders_deleted} stale folder(s) removed, #{result.words_relocated} word tile(s) relocated"

      next if dry_run

      # Only the pages the sync touched need a fresh preview. Board#generate_previews
      # is the real API (no bang, no args); in dev/test it raises an ArgumentError
      # about url_options outside a request, which is not a failure worth aborting on
      # — same rescue BuildBoardSetJob#generate_preview! uses.
      Boards::PredictiveLinkSet
        .collect(root, max_depth: Boards::NavRowSync::MAX_DEPTH,
                       exclude: ->(b) { b.user_id != root.user_id })
        .each do |board|
          board.generate_previews
        rescue ArgumentError => e
          raise unless e.message.include?("url_options")
        end
    rescue => e
      puts "  !! set ##{root.id} failed: #{e.message}"
    end

    if dry_run
      puts "Dry run only — #{sets} built set(s) to sync (#{tiles} nav tile(s), #{folders} stale folder(s), #{words} relocation(s)). Re-run with DRY_RUN=false to apply."
    else
      puts "Synced #{sets} set(s): #{tiles} nav tile(s) written, #{folders} stale folder(s) removed, #{words} word tile(s) relocated."
    end
  end
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `RAILS_ENV=test bundle exec rspec spec/tasks/board_builder_sync_nav_rows_spec.rb`
Expected: PASS — 2 examples, 0 failures

- [ ] **Step 5: Run the full affected suite**

Run:
```bash
RAILS_ENV=test bundle exec rspec spec/services/boards spec/sidekiq/build_board_set_job_spec.rb spec/tasks/board_builder_sync_nav_rows_spec.rb spec/db/seeds/board_builder_sets_spec.rb spec/requests/api/v1/board_builder_spec.rb
```
Expected: PASS — 0 failures. `spec/db/seeds/board_builder_sets_spec.rb` must be untouched and still green.

- [ ] **Step 6: Commit**

```bash
git add lib/tasks/board_builder.rake spec/tasks/board_builder_sync_nav_rows_spec.rb
git commit -m "feat(board-builder): backfill nav rows across already-built sets"
```

---

### Task 6: Documentation

**Files:**
- Modify: `.claude-notes/board-builder.md` (the nav-row bullet, ~line 660)
- Modify: `db/seeds/board_builder_sets/README.md` (the "nav row must be identical" section)
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: nothing.

**Background an implementer needs:**

`.claude-notes/` is gitignored — durable subsystem docs are force-added with `git add -f`. Per this repo's documentation rules, document the **invariant**, not the bug that motivated it, and keep the hub (`CLAUDE.md`) lean — this detail belongs in the spoke.

- [ ] **Step 1: Update the subsystem spoke**

In `.claude-notes/board-builder.md`, replace the opening sentences of the bullet beginning **"The nav row is identical on every board in a set (motor planning)."** with:

```markdown
- **The nav row is identical on every board in a set (motor planning).** The
  root's bottom **nav row** of folder tiles is reproduced **cell-for-cell** on
  every page at the root's grid dimensions, so a category is the same reach from
  anywhere. The tile for the page you're on links back to the **root** rather
  than at itself — it's both the you-are-here anchor and the way home, which is
  why there's no separate `Home` tile.
  - **`Boards::NavRowSync` is the enforcement mechanism; authoring is a
    convenience.** Authoring the row in the seed `.obf` files only covers the
    pages that ship *in* the seed set, and a build that adds a page (prebuilt
    fringe, AI-generated, My Favorites, Phrases) grows the **root's** grid alone
    — which is what pushed the seeded pages out of alignment. `BuildBoardSetJob`
    calls `Boards::NavRowSync` at the end-of-build chokepoint (before muting,
    reflow, and previews) to project the root's **final** row onto every page.
    Idempotent: tiles it owns carry `data["nav_tile"] = true`.
  - **`Boards::NavRegion`** derives the region: the bottom row, plus at most
    **one** row above it whose occupied cells are *all* folder tiles (the
    build's added pages). A content row holding a lone folder tile — Core 84's
    `More` — is **not** a nav row; that tile is pinned at its own cell instead.
    `NavRegion.align` first rotates the authored nav row back to the bottom,
    since `Board#add_image` appends growth *below* it.
  - **Robust sets only.** Legacy label-only starter trees (`home`,
    `daily_routine`) have no nav row and are skipped.
  - The **self tile is the one folder tile that speaks** — `NavRowSync` leaves
    `mute_name` off it, and `mute_dynamic_tile_names!` exempts a dynamic tile
    whose label matches its own board's name.
  - **Bottom-pinned on every screen.** `Boards::ScreenReflow.reflow!` takes
    `pinned_rows:` (default `0` — the original path for every non-builder
    caller); the job passes the region's row count so content packs first and
    the nav strip stays at the bottom on md/sm/xs. At a narrow column count the
    strip spans more rows — still bottom-pinned, still identical per page.
  - **Backfill:** `rake board_builder:sync_nav_rows` re-projects the row across
    every existing `builder_root` set (dry-run by default; `DRY_RUN=false` to
    apply, `USER_ID=N` to scope). Stale folder tiles are removed; a user's word
    tile in a nav cell is **relocated**, never deleted.
  - Built sets are **clones taken at build time**, so reseeding an aligned
    template only affects **new** builds — the rake task is what heals sets
    already in the wild.
```

- [ ] **Step 2: Update the seed authoring README**

In `db/seeds/board_builder_sets/README.md`, append to the end of the section **"The nav row must be identical on every board in a set"**:

```markdown
**Authoring covers the admin templates; the build enforces the rule.** These
`.obf` files are seeded as admin-owned boards and browsed on their own, so keep
authoring the nav row here — `spec/db/seeds/board_builder_sets_spec.rb` still
guards it. But a *built* set gets its nav row projected at build time by
`Boards::NavRowSync`, because the final row isn't knowable until the build
finishes adding pages (prebuilt fringe, AI-generated, My Favorites, Phrases).
That is also why the standalone `fringe-pages/*.obf` templates carry **no** nav
row: they're cloned into arbitrary sets and can't know their future root's.
```

- [ ] **Step 3: Add the changelog entry**

Add to the top section of `CHANGELOG.md`:

```markdown
- **Board Builder:** the category nav row is now identical on every page of a
  built set — including pages the build adds (Animals, My Favorites, Phrases,
  and the gestalt function boards) — and stays pinned to the bottom on tablets
  and phones. The tile for the page you're on speaks its word and takes you
  home. Existing sets are updated with `rake board_builder:sync_nav_rows`.
```

- [ ] **Step 4: Commit**

```bash
git add -f .claude-notes/board-builder.md
git add db/seeds/board_builder_sets/README.md CHANGELOG.md
git commit -m "docs(board-builder): document nav row sync as the enforcement mechanism"
```

---

## Deployment note

`rake board_builder:sync_nav_rows` mutates live production sets. Run it in this order after deploy:

1. `rake board_builder:sync_nav_rows` (dry run) — review the per-set report, especially the relocation and stale-folder counts.
2. `DRY_RUN=false USER_ID=<your own> rake board_builder:sync_nav_rows` — verify one set in the app first.
3. `DRY_RUN=false rake board_builder:sync_nav_rows` — apply to all.
